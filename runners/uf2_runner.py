# Copyright (c) 2023 Peter Johanson <peter@peterjohanson.com>
# Copyright (c) 2026 cormoran
#
# The code is based on https://github.com/zephyrproject-rtos/zephyr/blob/main/scripts/west_commands/runners/uf2.py
#
# SPDX-License-Identifier: Apache-2.0

"""UF2 runner (flash only) for UF2 compatible bootloaders with supporting touch-reset."""

from pathlib import Path
from shutil import copyfile
import time
import platform

from runners.core import RunnerCaps, ZephyrBinaryRunner

try:
    import psutil

    MISSING_PSUTIL = False
except ImportError:
    # This can happen when building the documentation for the
    # runners package if psutil is not on sys.path. This is fine
    # to ignore in that case.
    MISSING_PSUTIL = True

try:
    import serial

    MISSING_SERIAL = False
except ImportError:
    MISSING_SERIAL = True


class UF2BinaryRunner(ZephyrBinaryRunner):
    """Runner front-end for copying to UF2 USB-MSC mounts."""

    def __init__(
        self,
        cfg,
        board_id=None,
        touch_reset=True,
        touch_reset_port=None,
        touch_reset_baud_rate=1200,
    ):
        super().__init__(cfg)
        self.board_id = board_id
        self.touch_reset = touch_reset
        self.touch_reset_port = touch_reset_port
        self.touch_reset_baud_rate = touch_reset_baud_rate

    @classmethod
    def name(cls):
        return "uf2-reset"

    @classmethod
    def capabilities(cls):
        return RunnerCaps(commands={"flash"})

    @classmethod
    def do_add_parser(cls, parser):
        parser.add_argument(
            "--board-id",
            dest="board_id",
            help="Board-ID value to match from INFO_UF2.TXT",
        )
        parser.add_argument(
            "--no-touch-reset",
            dest="no_touch_reset",
            action="store_true",
            help="Do not trigger touch-reset before copying the UF2 file",
        )
        parser.add_argument(
            "--touch-reset-port",
            dest="touch_reset_port",
            help="""Trigger touch-reset with the specified port.
                            The port is opened with the specified baud rate and closed immediately after.
                            Devices which supports touch-reset (Arduino devices or using zmk-feature-cdc-acm-bootloader-trigger) will enter bootloader mode.
                            """,
        )
        parser.add_argument(
            "--touch-reset-baud-rate",
            type=int,
            default=1200,
            help="Baud rate to use when --touch-reset is specified",
        )

    @classmethod
    def do_create(cls, cfg, args):
        return UF2BinaryRunner(
            cfg,
            board_id=args.board_id,
            touch_reset=not args.no_touch_reset,
            touch_reset_port=args.touch_reset_port,
            touch_reset_baud_rate=args.touch_reset_baud_rate,
        )

    @staticmethod
    def get_uf2_info_path(part) -> Path:
        return Path(part.mountpoint) / "INFO_UF2.TXT"

    @staticmethod
    def is_uf2_partition(part):
        try:
            return (
                part.fstype in ["vfat", "FAT", "msdos"]
            ) and UF2BinaryRunner.get_uf2_info_path(part).is_file()
        except PermissionError:
            return False

    @staticmethod
    def get_uf2_info(part):
        lines = UF2BinaryRunner.get_uf2_info_path(part).read_text().splitlines()

        lines = lines[1:]  # Skip the first summary line

        def split_uf2_info(line: str):
            k, _, val = line.partition(":")
            return k.strip(), val.strip()

        return {k: v for k, v in (split_uf2_info(line) for line in lines) if k and v}

    def match_board_id(self, part):
        info = self.get_uf2_info(part)

        return info.get("Board-ID") == self.board_id

    def get_uf2_partitions(self):
        parts = [
            part for part in psutil.disk_partitions() if self.is_uf2_partition(part)
        ]

        if (self.board_id is not None) and parts:
            parts = [part for part in parts if self.match_board_id(part)]
            if not parts:
                self.logger.warning(
                    "Discovered UF2 partitions don't match Board-ID '%s'", self.board_id
                )

        return parts

    def copy_uf2_to_partition(self, part):
        self.ensure_output("uf2")

        dest = Path(part.mountpoint) / Path(self.cfg.uf2_file).name
        copyfile(self.cfg.uf2_file, dest)

    def _touch_reset(self):
        if MISSING_SERIAL:
            raise RuntimeError(
                "touch reset requested but could not import pyserial; Please install pyserial to use this feature."
            )
        self.logger.info("Triggering touch reset on port '%s'", self.touch_reset_port)
        with serial.Serial(self.touch_reset_port, self.touch_reset_baud_rate) as ser:
            pass  # close
        time.sleep(1)  # Give the device some time to reset and re-enumerate

    def do_run_powershell(self):
        import subprocess

        script_path = Path(__file__).parent / "uf2_runner.ps1"
        uf2File = subprocess.run(
            ["wslpath", "-w", self.cfg.uf2_file], capture_output=True
        ).stdout.strip()
        cmd = [
            "powershell.exe",
            "-ExecutionPolicy",
            "Bypass",
            "-File",
            str(script_path),
            "--Uf2File",
            uf2File,
        ]
        if self.touch_reset:
            if self.touch_reset_port:
                cmd += ["--COMPort", self.touch_reset_port]
            if self.touch_reset_baud_rate:
                cmd += ["--TouchResetBaudRate", str(self.touch_reset_baud_rate)]
        else:
            cmd += ["--NoTouchReset"]
        subprocess.run(cmd, check=True)

    def is_wsl(self):
        return "microsoft" in platform.uname().release.lower()

    def do_run(self, command, **kwargs):
        if self.is_wsl():
            return self.do_run_powershell()

        if MISSING_PSUTIL:
            raise RuntimeError(
                "could not import psutil; something may be wrong with the "
                "python environment"
            )

        if self.touch_reset and self.touch_reset_port:
            self._touch_reset()

        partitions = self.get_uf2_partitions()
        if not partitions:
            raise RuntimeError("No matching UF2 partitions found")

        if len(partitions) > 1:
            raise RuntimeError("More than one matching UF2 partitions found")

        part = partitions[0]
        self.logger.info("Copying UF2 file to '%s'", part.mountpoint)
        self.copy_uf2_to_partition(part)
