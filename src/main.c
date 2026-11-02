/**
******************************************************************************
* Copyright (c) 2026 Nordic Semiconductor ASA
* Filename : main.c
* Date(DD-MM-YYYY)    Modification    Name
* ----------------    ------------    ----
* 26-10-2026          Created         JF
*******************************************************************************
*/

/* Includes ------------------------------------------------------------------*/
#include <zephyr/kernel.h>
#include <zephyr/logging/log.h>
#include <zephyr/sys/poweroff.h>
#if defined(CONFIG_HWINFO)
#include <zephyr/drivers/hwinfo.h>
#endif
#if defined(CONFIG_APP_GPIO_WAKEUP_ENABLE)
#include <zephyr/drivers/gpio.h>
#endif
#if defined(CONFIG_APP_GRTC_WAKEUP_ENABLE)
#include <zephyr/drivers/timer/nrf_grtc_timer.h>
#endif
#if defined(CONFIG_APP_SYS_CLOCK_DISABLE)
#include <zephyr/drivers/timer/system_timer.h>
#endif
#if defined(CONFIG_APP_USE_RETAINED_MEM)
#include "retained.h"
#endif
#include <zephyr/cache.h>
#include <hal/nrf_memconf.h>

/* Macro----------------------------------------------------------------------*/
#define LOG_MODULE_NAME main
LOG_MODULE_REGISTER(LOG_MODULE_NAME, CONFIG_LOG_DEFAULT_LEVEL);

/*
 * RAM blocks outside the application RAM that stay retained in System OFF.
 *
 * MEMCONF POWER[1].RET bit n controls MEM[n], which is block 32 + n; the reset value is all
 * ones (retained). sys_poweroff() and nrfx_ram_ctrl only touch POWER[0] (the application RAM,
 * 8 x 32 KB on nRF54L15) and bit 0 of POWER[1] (block 32, VPR hibernation RAM), so the blocks
 * below keep drawing retention current in System OFF (about 0.2 uA measured on nRF54L15).
 * Nothing in them has to survive: waking up from System OFF is a reset.
 *
 *   bit  block  nRF54L15 / L10 / L05        nRF54LM20A/B   nRF54LS05A/B
 *   1    33     ICACHE tag + data           ICACHE         ICACHE
 *   2    34     CRACEN PKE code RAM         USBHS RAM      not listed
 *   3    35     CRACEN KeyRAM               not listed     not listed
 */

#if defined(CONFIG_SOC_NRF54L15)
#define POWER1_RET_OFF_MASK \
    (MEMCONF_POWER_RET_MEM1_Msk | MEMCONF_POWER_RET_MEM2_Msk | MEMCONF_POWER_RET_MEM3_Msk)
#elif defined(CONFIG_SOC_NRF54LM20A) || defined(CONFIG_SOC_NRF54LM20B)
#define POWER1_RET_OFF_MASK (MEMCONF_POWER_RET_MEM1_Msk | MEMCONF_POWER_RET_MEM2_Msk)
#elif defined(CONFIG_SOC_NRF54LS05A) || defined(CONFIG_SOC_NRF54LS05B)
#define POWER1_RET_OFF_MASK MEMCONF_POWER_RET_MEM1_Msk
#else
#define POWER1_RET_OFF_MASK 0
#endif

/* Private typedef -----------------------------------------------------------*/

/* Private function prototypes------------------------------------------------*/
static void report_boot(void);
static int prepare_wakeup(void);
#if defined(CONFIG_APP_SYS_CLOCK_DISABLE)
static void system_clock_stop(void);
#endif
static void extra_ram_off(void);

/* Global variables ----------------------------------------------------------*/

/* Private variables ---------------------------------------------------------*/
#if defined(CONFIG_APP_GPIO_WAKEUP_ENABLE)
static const struct gpio_dt_spec sw0 = GPIO_DT_SPEC_GET(DT_ALIAS(sw0), gpios);
#endif

/* Macro ---------------------------------------------------------------------*/

/* Exported functions --------------------------------------------------------*/
/*
 * Enter System OFF on every boot, independent of the reset cause.
 *
 * Wake-up source (Kconfig, snippets pinwake / grtcwake): sw0 level (APP_GPIO_WAKEUP_ENABLE),
 * GRTC timer (APP_GRTC_WAKEUP_ENABLE), or none (default; restart only by pin reset or power
 * cycle).
 *
 * RAM in System OFF (Kconfig, snippet retram): none retained (default), the 4 KB retained_mem
 * region (APP_USE_RETAINED_MEM). The POWER[1] blocks (ICACHE, CRACEN, USBHS) that sys_poweroff()
 * leaves retained are always switched off.
 */
int main(void)
{
    LOG_PRINTK("system_off sample started\n");

    report_boot();

    if (prepare_wakeup() < 0)
    {
        LOG_ERR("Wake-up source setup failed, entering System OFF without it");
    }

    /*
     * Go to System OFF unconditionally; the reset cause is never used as a condition.
     * Without a wake-up source only a reset or a power cycle starts the device again.
     *
     * Order matters. Everything that logs or uses a kernel timeout comes before the system
     * clock is stopped; from there on only register writes are allowed.
     */
#if defined(CONFIG_APP_SYS_CLOCK_DISABLE)
    system_clock_stop();
#endif
    extra_ram_off();
    sys_poweroff();

    return 0;
}

/* Override functions -------------------------------------------------------*/

/* Private Functions ---------------------------------------------------------*/

/**
 * @brief Print the reset cause and the retained boot counters.
 *
 * Informational only, nothing here changes whether the device goes to System OFF.
 */
static void report_boot(void)
{
#if defined(CONFIG_HWINFO)
    uint32_t cause = 0;

    if (hwinfo_get_reset_cause(&cause) == 0)
    {
        LOG_INF("Reset cause 0x%08x", cause);
    }
    else
    {
        LOG_INF("Reset cause not available");
    }
    (void)hwinfo_clear_reset_cause();
#endif

#if defined(CONFIG_APP_USE_RETAINED_MEM)
    /* Invalid (e.g. after a cold power-up) retained data is reset by retained_validate() */
    bool retained_ok = retained_validate();

    retained.boots += 1;
    retained.off_count += 1;
    retained_update();

    LOG_INF("Retained data: %s, boots %u, off count %u", retained_ok ? "valid" : "INVALID",
            retained.boots, retained.off_count);
#endif
}

/**
 * @brief Arm the wake-up sources selected by Kconfig.
 *
 * @return 0 on success, a negative errno otherwise.
 */
static int prepare_wakeup(void)
{
    int rc = 0;

#if defined(CONFIG_APP_GPIO_WAKEUP_ENABLE)
    rc = gpio_pin_configure_dt(&sw0, GPIO_INPUT);
    if (rc < 0)
    {
        LOG_ERR("sw0 configure failed (%d)", rc);
        return rc;
    }

    /*
     * A level-active wake-up fires at once if the button is still held, so wait for the
     * release. A button that stays pressed must not block System OFF for ever: give up after
     * the timeout and enter System OFF without this wake-up source.
     */
    int64_t release_deadline = k_uptime_get() + CONFIG_APP_GPIO_RELEASE_TIMEOUT_MS;

    while (gpio_pin_get_dt(&sw0) > 0)
    {
        if (k_uptime_get() >= release_deadline)
        {
            LOG_WRN("sw0 still pressed after %d ms, sw0 wake-up not armed",
                    CONFIG_APP_GPIO_RELEASE_TIMEOUT_MS);
            return -ETIMEDOUT;
        }
        k_msleep(10);
    }

    rc = gpio_pin_interrupt_configure_dt(&sw0, GPIO_INT_LEVEL_ACTIVE);
    if (rc < 0)
    {
        LOG_ERR("sw0 interrupt configure failed (%d)", rc);
        return rc;
    }
    LOG_INF("Entering System OFF; press sw0 to restart");
#endif

#if defined(CONFIG_APP_GRTC_WAKEUP_ENABLE)
    /* Arm GRTC last, right before entering System OFF; nothing is logged after this. */
    LOG_INF("Entering System OFF; wait %d s to restart", CONFIG_APP_GRTC_WAKEUP_SECONDS);
    rc = z_nrf_grtc_wakeup_prepare((uint64_t)CONFIG_APP_GRTC_WAKEUP_SECONDS * USEC_PER_SEC);
    if (rc < 0)
    {
        LOG_ERR("GRTC wake-up prepare failed (%d)", rc);
        return rc;
    }
#endif

    return rc;
}

#if defined(CONFIG_APP_SYS_CLOCK_DISABLE)
/**
 * @brief Stop the system clock (GRTC and low-frequency clock).
 *
 * Nothing may log or use a kernel timeout after this call.
 */
static void system_clock_stop(void)
{
#if defined(CONFIG_LOG)
    /*
     * The log backend suspends the UART from the system work queue after the last print. If
     * the system clock is stopped first, the scheduler hangs in sys_clock_elapsed() reading the
     * stopped GRTC. Let the pending work finish first.
     */
    k_msleep(100);
#endif
    sys_clock_disable();
}
#endif

/**
 * @brief Switch off the System OFF retention of the POWER[1] RAM blocks that sys_poweroff()
 *        leaves retained (ICACHE, CRACEN, USBHS, see POWER1_RET_OFF_MASK).
 *
 * The application RAM and the retained_mem region are handled by sys_poweroff() itself.
 */
static void extra_ram_off(void)
{
#if defined(CONFIG_SOC_NRF54LS05B) && !defined(CONFIG_APP_USE_RETAINED_MEM)
    /*
     * nrfx_ram_ctrl knows only two 32 KB RAM sections for nRF54LS05 at v3.4.1, but the B
     * variant has a third one (0x20010000-0x20017FFF), so sys_poweroff() leaves its
     * retention on.
     */
    NRF_MEMCONF->POWER[0].RET &= ~MEMCONF_POWER_RET_MEM2_Msk;
#endif
#if POWER1_RET_OFF_MASK
    /* The ICACHE block (bit 1) must not be switched off while the cache is enabled */
    sys_cache_instr_disable();
    NRF_MEMCONF->POWER[1].RET &= ~POWER1_RET_OFF_MASK;
#endif
}

/* Macro ---------------------------------------------------------------------*/
