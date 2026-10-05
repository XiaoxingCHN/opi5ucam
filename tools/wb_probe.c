/* wb_probe.c — quantify white-balance behaviour of SUA133GC Bayer stream.
 * Prints per-channel means of captured frames under different camera settings:
 *   1. baseline (current settings)
 *   2. ColorTemperatureAutoSel=off
 *   3. after WBOnce command (camera one-shot WB)
 *   4. RGain bumped to 150 (does the gain even reach the Bayer stream?)
 * Build: gcc -O2 -o wb_probe wb_probe.c $(pkg-config --cflags --libs aravis-0.8)
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <arv.h>

static int W = 1280, H = 1024;

/* RGGB channel means over n frames */
static int capture_means(ArvCamera *cam, const char *label, int n_frames)
{
    GError *err = NULL;
    ArvStream *stream = arv_camera_create_stream(cam, NULL, NULL, &err);
    if (!stream) { printf("  %s: no stream: %s\n", label, err ? err->message : "?"); g_clear_error(&err); return -1; }
    size_t payload = arv_camera_get_payload(cam, &err); g_clear_error(&err);
    for (int i = 0; i < 8; i++) arv_stream_push_buffer(stream, arv_buffer_new(payload, NULL));
    arv_camera_start_acquisition(cam, &err); g_clear_error(&err);

    double sum_r = 0, sum_g = 0, sum_b = 0; int used = 0;
    int target = n_frames + 4;
    for (int f = 0; f < target; f++) {
        ArvBuffer *b = arv_stream_timeout_pop_buffer(stream, 1000000);
        if (!b) break;
        if (arv_buffer_get_status(b) == ARV_BUFFER_STATUS_SUCCESS && ++used > 4) {
            size_t sz = 0;
            const guint8 *d = arv_buffer_get_data(b, &sz);
            for (int y = 0; y < H; y += 2) {
                for (int x = 0; x < W; x += 2) {
                    sum_r += d[y * W + x];            /* even row, even col */
                    sum_g += d[y * W + x + 1];        /* even row, odd col  */
                    sum_g += d[(y + 1) * W + x];      /* odd row, even col  */
                    sum_b += d[(y + 1) * W + x + 1];  /* odd row, odd col   */
                }
            }
        }
        arv_stream_push_buffer(stream, b);
    }
    arv_camera_stop_acquisition(cam, &err); g_clear_error(&err);
    g_object_unref(stream);
    if (used <= 4) { printf("  %s: no frames\n", label); return -1; }
    int n = (H / 2) * (W / 2);  /* samples per quadsite */
    printf("  %-28s R=%6.1f  G=%6.1f  B=%6.1f   (%d frames)\n", label,
           sum_r / n, sum_g / (2 * n), sum_b / n, used - 4);
    return 0;
}

static void get_gains(ArvCamera *cam)
{
    GError *err = NULL;
    ArvDevice *dev = arv_camera_get_device(cam);
    gint r = arv_device_get_integer_feature_value(dev, "RGain", &err); g_clear_error(&err);
    gint g = arv_device_get_integer_feature_value(dev, "GGain", &err); g_clear_error(&err);
    gint b = arv_device_get_integer_feature_value(dev, "BGain", &err); g_clear_error(&err);
    gboolean a = arv_device_get_boolean_feature_value(dev, "ColorTemperatureAutoSel", &err); g_clear_error(&err);
    printf("  gains R=%d G=%d B=%d  AutoSel=%d\n", r, g, b, a);
}

int main(void)
{
    GError *err = NULL;
    ArvCamera *cam = arv_camera_new(NULL, &err);
    if (!cam) { printf("no camera: %s\n", err ? err->message : "?"); return 1; }

    arv_camera_set_region(cam, 0, 0, W, H, &err); g_clear_error(&err);
    arv_camera_set_pixel_format(cam, ARV_PIXEL_FORMAT_BAYER_RG_8, &err); g_clear_error(&err);
    arv_camera_set_exposure_time_auto(cam, ARV_AUTO_OFF, &err); g_clear_error(&err);
    arv_camera_set_exposure_time(cam, 10000.0, &err); g_clear_error(&err);

    printf("== baseline\n");   get_gains(cam); capture_means(cam, "baseline", 10);

    printf("== ColorTemperatureAutoSel=off\n");
    arv_device_set_boolean_feature_value(arv_camera_get_device(cam), "ColorTemperatureAutoSel", FALSE, &err);
    if (err) { printf("  set failed: %s\n", err->message); g_clear_error(&err); }
    get_gains(cam); capture_means(cam, "autosel_off", 10);

    printf("== WBOnce (camera one-shot WB)\n");
    arv_device_execute_command(arv_camera_get_device(cam), "WBOnce", &err);
    if (err) { printf("  WBOnce failed: %s\n", err->message); g_clear_error(&err); }
    else { sleep(3); get_gains(cam); capture_means(cam, "after_wb_once", 10); }

    printf("== RGain=150 (gain reaches stream?)\n");
    arv_device_set_integer_feature_value(arv_camera_get_device(cam), "RGain", 150, &err); g_clear_error(&err);
    get_gains(cam); capture_means(cam, "rgain_150", 10);
    arv_device_set_integer_feature_value(arv_camera_get_device(cam), "RGain", 100, &err); g_clear_error(&err);

    printf("== drift check: 20s idle with AutoSel back on\n");
    arv_device_set_boolean_feature_value(arv_camera_get_device(cam), "ColorTemperatureAutoSel", TRUE, &err); g_clear_error(&err);
    get_gains(cam); capture_means(cam, "drift_t0", 10);
    sleep(20);
    get_gains(cam); capture_means(cam, "drift_t20", 10);
    arv_device_set_boolean_feature_value(arv_camera_get_device(cam), "ColorTemperatureAutoSel", FALSE, &err); g_clear_error(&err);

    g_object_unref(cam);
    return 0;
}
