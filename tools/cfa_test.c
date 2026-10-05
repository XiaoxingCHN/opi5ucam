/* cfa_test.c — determine the physical Bayer CFA layout of SUA133GC.
 * Boosts RGain / BGain in isolation and reports which of the four Bayer
 * sites (S00=even/even, S01=even/odd, S10=odd/even, S11=odd/odd) responds.
 *
 *   camera-R site = the site that jumps with RGain
 *   camera-B site = the site that jumps with BGain
 * S00=R & S11=B -> RGGB ; S00=B & S11=R -> BGGR ; etc.
 */
#include <stdio.h>
#include <unistd.h>
#include <arv.h>

#define W 1280
#define H 1024

static void capture_sites(ArvCamera *cam, const char *label, double m[4])
{
    GError *err = NULL;
    ArvStream *stream = arv_camera_create_stream(cam, NULL, NULL, &err);
    if (!stream) { printf("  %s: no stream\n", label); return; }
    size_t payload = arv_camera_get_payload(cam, &err); g_clear_error(&err);
    for (int i = 0; i < 8; i++) arv_stream_push_buffer(stream, arv_buffer_new(payload, NULL));
    arv_camera_start_acquisition(cam, &err); g_clear_error(&err);

    double s[4] = {0, 0, 0, 0};
    int used = 0;
    for (int f = 0; f < 14; f++) {
        ArvBuffer *b = arv_stream_timeout_pop_buffer(stream, 1000000);
        if (!b) break;
        if (arv_buffer_get_status(b) == ARV_BUFFER_STATUS_SUCCESS && ++used > 4) {
            size_t sz = 0;
            const guint8 *d = arv_buffer_get_data(b, &sz);
            for (int y = 0; y < H; y += 2)
                for (int x = 0; x < W; x += 2) {
                    s[0] += d[y * W + x];
                    s[1] += d[y * W + x + 1];
                    s[2] += d[(y + 1) * W + x];
                    s[3] += d[(y + 1) * W + x + 1];
                }
        }
        arv_stream_push_buffer(stream, b);
    }
    arv_camera_stop_acquisition(cam, &err); g_clear_error(&err);
    g_object_unref(stream);
    int n = (H / 2) * (W / 2);
    for (int i = 0; i < 4; i++) m[i] = s[i] / n;
    printf("  %-14s S00=%6.1f S01=%6.1f S10=%6.1f S11=%6.1f  (%d fr)\n",
           label, m[0], m[1], m[2], m[3], used > 4 ? used - 4 : 0);
}

static void set_gain(ArvCamera *cam, const char *f, int v)
{
    GError *err = NULL;
    arv_device_set_integer_feature_value(arv_camera_get_device(cam), f, v, &err);
    g_clear_error(&err);
}

int main(void)
{
    GError *err = NULL;
    ArvCamera *cam = arv_camera_new(NULL, &err);
    if (!cam) { printf("no camera\n"); return 1; }
    double m[4];

    arv_camera_set_region(cam, 0, 0, W, H, &err); g_clear_error(&err);
    arv_camera_set_pixel_format(cam, ARV_PIXEL_FORMAT_BAYER_RG_8, &err); g_clear_error(&err);
    arv_camera_set_exposure_time_auto(cam, ARV_AUTO_OFF, &err); g_clear_error(&err);
    arv_camera_set_exposure_time(cam, 10000.0, &err); g_clear_error(&err);

    set_gain(cam, "RGain", 100); set_gain(cam, "GGain", 100); set_gain(cam, "BGain", 100);
    capture_sites(cam, "gains 100/100/100", m);

    set_gain(cam, "RGain", 250);
    capture_sites(cam, "RGain=250", m);
    set_gain(cam, "RGain", 100);

    set_gain(cam, "BGain", 250);
    capture_sites(cam, "BGain=250", m);
    set_gain(cam, "BGain", 100);

    g_object_unref(cam);
    printf("\nS00=even/even S01=even/odd S10=odd/even S11=odd/odd\n");
    printf("site jumping with RGain = camera-R; with BGain = camera-B\n");
    return 0;
}
