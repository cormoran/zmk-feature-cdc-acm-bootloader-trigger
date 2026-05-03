if (CONFIG_ZMK_CDC_ACM_BOOTLOADER_TRIGGER_USE_UF2_RESET_RUNNER)
    board_finalize_runner_args(uf2-reset)
endif()

if(CONFIG_ZMK_CDC_ACM_BOOTLOADER_TRIGGER)
    zephyr_library()
    zephyr_library_sources(src/cdc_acm_bootloader_trigger.c)
    zephyr_library_include_directories(${CMAKE_SOURCE_DIR}/include)
endif()
