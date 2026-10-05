#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <arv.h>
static const char *sname(ArvBufferStatus s){
  switch(s){
  case ARV_BUFFER_STATUS_SUCCESS:return "SUCCESS";
  case ARV_BUFFER_STATUS_CLEARED:return "CLEARED";
  case ARV_BUFFER_STATUS_TIMEOUT:return "TIMEOUT";
  case ARV_BUFFER_STATUS_MISSING_PACKETS:return "MISSING_PACKETS";
  case ARV_BUFFER_STATUS_WRONG_PACKET_ID:return "WRONG_PACKET_ID";
  case ARV_BUFFER_STATUS_SIZE_MISMATCH:return "SIZE_MISMATCH";
  case ARV_BUFFER_STATUS_ABORTED:return "ABORTED";
  default:return "UNKNOWN";}
}
static int cnt[10];
/* BGGR nearest-neighbor debayer -> RGB24 for ffplay.
 * Physical CFA is BGGR (B at even/even, R at odd/odd — measured, cfa_test.c);
 * the RGGB site logic below yields per-pixel [B,G,R], so the final store
 * writes b,g,r to produce true RGB byte order. */
static void debayer_rggb(const unsigned char *src, unsigned char *dst, int w, int h) {
  for (int y = 0; y < h; y++) {
    for (int x = 0; x < w; x++) {
      int r, g, b;
      int even_row = !(y & 1), even_col = !(x & 1);
      if (even_row && even_col)      { r = src[y*w+x]; g = (src[y*w + (x+1<w?x+1:x)] + src[(y+1<h?y+1:y)*w + x]) >> 1; b = src[(y+1<h?y+1:y)*w + (x+1<w?x+1:x)]; }
      else if (even_row && !even_col){ r = src[y*w + (x>0?x-1:x)]; g = src[y*w+x]; b = src[(y+1<h?y+1:y)*w + x]; }
      else if (!even_row && even_col){ r = src[(y>0?y-1:y)*w + x]; g = src[y*w+x]; b = src[y*w + (x+1<w?x+1:x)]; }
      else                           { r = src[(y>0?y-1:y)*w + (x>0?x-1:x)]; g = (src[(y>0?y-1:y)*w + x] + src[y*w + (x>0?x-1:x)]) >> 1; b = src[y*w+x]; }
      *dst++ = (unsigned char)(b > 255 ? 255 : b);
      *dst++ = (unsigned char)(g > 255 ? 255 : g);
      *dst++ = (unsigned char)(r > 255 ? 255 : r);
    }
  }
}
int main(int argc, char **argv) {
    int total = (argc > 1) ? atoi(argv[1]) : 1800;
    int dump = (argc > 2 && strcmp(argv[2], "dump") == 0);
    ArvCamera *cam = arv_camera_new(NULL, NULL);
    if (!cam) { printf("NO_CAMERA\n"); return 1; }
    GError *err = NULL;
    gint x0,y0,w,h; arv_camera_get_region(cam,&x0,&y0,&w,&h,&err); g_clear_error(&err);
    arv_camera_set_pixel_format(cam, ARV_PIXEL_FORMAT_BAYER_RG_8, &err); g_clear_error(&err);
    guint64 pf = arv_camera_get_pixel_format(cam, &err); g_clear_error(&err);
    arv_camera_set_exposure_time_auto(cam, ARV_AUTO_OFF, &err); g_clear_error(&err);
    arv_camera_set_exposure_time(cam, 10000.0, &err); g_clear_error(&err);
    {   /* WB: kill auto color temp (drift), one-shot WB to fix the green cast */
        ArvDevice *dev = arv_camera_get_device(cam);
        GError *wbe = NULL;
        arv_device_set_boolean_feature_value(dev, "ColorTemperatureAutoSel", FALSE, &wbe); g_clear_error(&wbe);
        arv_device_execute_command(dev, "WBOnce", &wbe);
        if (!wbe) sleep(3); g_clear_error(&wbe);
    }
    size_t payload = arv_camera_get_payload(cam, &err); g_clear_error(&err);
    printf("region=%dx%d fmt=0x%08lx payload=%zu\n", w, h, (unsigned long)pf, payload); fflush(stdout);
    ArvStream *stream = arv_camera_create_stream(cam, NULL, NULL, &err);
    if (!stream) { printf("NO_STREAM: %s\n", err ? err->message : "?"); return 1; }
    for (int i = 0; i < 16; i++) arv_stream_push_buffer(stream, arv_buffer_new(payload, NULL));
    arv_camera_start_acquisition(cam, &err); g_clear_error(&err);
    unsigned char *rgb = dump ? malloc((size_t)w * h * 3) : NULL;
    int frames=0, pop_timeouts=0, dropped=0, shown=0;
    time_t start=time(NULL), t0=start;
    while (time(NULL)-start < total) {
        guint n_in=0, n_out=0; arv_stream_get_n_buffers(stream, &n_in, &n_out);
        while (n_out > 2) { ArvBuffer *drop = arv_stream_timeout_pop_buffer(stream, 0); if (!drop) break; dropped++; arv_stream_push_buffer(stream, drop); n_out--; }
        ArvBuffer *b = arv_stream_timeout_pop_buffer(stream, 3000000);
        if (b) {
            ArvBufferStatus s = arv_buffer_get_status(b);
            int idx = (int)s; if (idx<0||idx>9) idx=9; cnt[idx]++;
            if (s==ARV_BUFFER_STATUS_SUCCESS) {
                frames++;
                if (dump) { size_t sz=0; const unsigned char *d = arv_buffer_get_data(b, &sz);
                            debayer_rggb(d, rgb, w, h); fwrite(rgb, 1, (size_t)w*h*3, stdout); }
            }
            if (shown<6) { printf("buf[%d] status=%s\n", shown, sname(s)); shown++; fflush(stdout); }
            arv_stream_push_buffer(stream, b);
        } else pop_timeouts++;
        time_t now=time(NULL);
        if (now-t0 >= 60) {
            int el=(int)(now-start);
            printf("[%02d:%02d] frames=%d dropped=%d pop-timeouts=%d MISSING=%d OTHER=%d\n",
              el/60, el%60, frames, dropped, pop_timeouts, cnt[3], cnt[4]+cnt[5]+cnt[7]+cnt[9]);
            fflush(stdout); t0=now;
        }
    }
    arv_camera_stop_acquisition(cam,&err); g_clear_error(&err);
    printf("RESULT frames=%d dropped=%d pop-timeouts=%d MISSING=%d OTHER=%d dur=%ds\n",
      frames, dropped, pop_timeouts, cnt[3], cnt[4]+cnt[5]+cnt[7]+cnt[9], (int)(time(NULL)-start));
    return 0;
}
