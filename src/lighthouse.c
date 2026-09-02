/* totem lighthouse — boot-stage LED diagnostics without USB.
 *
 * XIAO nRF52840 user blue LED = P0.06. Polarity is board-dependent, so all
 * patterns are built from level pairs; bursts are countable either way and
 * the heartbeat toggles continuously (always visible).
 *
 *   2 fast blinks  → POST_KERNEL init reached
 *   5 fast blinks  → APPLICATION init reached
 *   slow heartbeat → kernel alive past boot (k_timer)
 */
#include <zephyr/init.h>
#include <zephyr/kernel.h>
#include <zephyr/drivers/gpio.h>

#define LED_PORT_NODE DT_NODELABEL(gpio0)
#define LED_PIN 6
#define BLINK_ON_MS 60
#define BLINK_OFF_MS 140

static const struct device *ledp;
static unsigned level;

static void led_write(unsigned v)
{
	level = v ? 1 : 0;
	gpio_pin_set(ledp, LED_PIN, level);
}

static void blink_burst(uint8_t n)
{
	for (uint8_t i = 0; i < n; i++) {
		led_write(!level); /* toggle to the other rail */
		k_busy_wait(BLINK_ON_MS * 1000);
		led_write(!level); /* toggle back */
		k_busy_wait(BLINK_OFF_MS * 1000);
	}
}

static void heartbeat(struct k_timer *t)
{
	ARG_UNUSED(t);
	gpio_pin_toggle(ledp, LED_PIN);
}

static K_TIMER_DEFINE(hb_timer, heartbeat, NULL);

static int lighthouse_post_kernel(const struct device *dev)
{
	ARG_UNUSED(dev);
	ledp = DEVICE_DT_GET(LED_PORT_NODE);
	if (!device_is_ready(ledp)) {
		return 0; /* stay dark, do not block boot */
	}
	gpio_pin_configure(ledp, LED_PIN, GPIO_OUTPUT_INACTIVE);
	level = 0;
	blink_burst(2);
	return 0;
}
SYS_INIT(lighthouse_post_kernel, POST_KERNEL, 90);

static int lighthouse_application(const struct device *dev)
{
	ARG_UNUSED(dev);
	if (device_is_ready(ledp)) {
		blink_burst(5);
	}
	k_timer_start(&hb_timer, K_MSEC(CONFIG_TOTEM_LIGHTHOUSE_HEARTBEAT_MS),
		     K_MSEC(CONFIG_TOTEM_LIGHTHOUSE_HEARTBEAT_MS));
	return 0;
}
SYS_INIT(lighthouse_application, APPLICATION, 90);
