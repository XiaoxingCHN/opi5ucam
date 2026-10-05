// aravis_camera_node.cpp — ROS2 Humble node for MindVision SUA133GC (USB3 Vision).
//
// Streams BayerRG8 from the camera via Aravis 0.8 and publishes
//   <camera_name>/image_raw      (image_transport camera publisher, + camera_info)
// encoding rgb8 (NN debayer) by default, or bayer_rggb8 (raw) via parameter.
//
// Built-in link recovery state machine (the platform's SS link dies silently):
//   STREAMING   : pop/publish loop; 1 s health tick watches frame counter
//   REOPEN      : stop grab, recreate camera+stream (bootstrap may fail)
//   USB_RECOVER : run usb_recover.sh (VBUS power cycle = electrical replug;
//                 script refuses when another process holds the device)
//   WAIT_DEVICE : poll sysfs until the camera re-enumerates
//   COOLDOWN    : exponential backoff (1 s .. 30 s) before retrying USB_RECOVER
#include <arv.h>

#include <image_transport/image_transport.hpp>
#include <camera_info_manager/camera_info_manager.hpp>
#include <rclcpp/rclcpp.hpp>
#include <sensor_msgs/msg/camera_info.hpp>
#include <sensor_msgs/msg/image.hpp>

#include <atomic>
#include <chrono>
#include <cstdio>
#include <memory>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

namespace sua_aravis_camera
{

using sensor_msgs::msg::CameraInfo;
using sensor_msgs::msg::Image;

class AravisCameraNode : public rclcpp::Node
{
public:
  explicit AravisCameraNode(const rclcpp::NodeOptions & options = rclcpp::NodeOptions())
  : Node("aravis_camera_node", options)
  {
    camera_name_ = declare_parameter<std::string>("camera_name", "mv_camera");
    frame_id_ = declare_parameter<std::string>("camera_optical_frame", "camera_optical_frame");
    camera_info_url_ = declare_parameter<std::string>("camera_info_url", "");
    exposure_time_us_ = declare_parameter<double>("exposure_time", 10000.0);
    use_sensor_data_qos_ = declare_parameter<bool>("use_sensor_data_qos", false);
    output_encoding_ = declare_parameter<std::string>("output_encoding", "rgb8");
    stall_seconds_ = declare_parameter<double>("stream_stall_seconds", 5.0);
    recover_script_ =
      declare_parameter<std::string>("usb_recover_script", "/usr/local/sbin/usb_recover.sh");
    wb_mode_ = declare_parameter<std::string>("wb_mode", "once");
    wb_rgain_ = declare_parameter<int>("wb_rgain", 100);
    wb_ggain_ = declare_parameter<int>("wb_ggain", 100);
    wb_bgain_ = declare_parameter<int>("wb_bgain", 100);
    // Physical CFA measured with gain-anchor test (~/aravis/cfa_test.c):
    // B at even/even, R at odd/odd => BGGR (despite the BAYER_RG_8 register).
    bayer_pattern_ = declare_parameter<std::string>("bayer_pattern", "bggr");
    if (bayer_pattern_ != "rggb" && bayer_pattern_ != "bggr") {
      RCLCPP_WARN(get_logger(), "bayer_pattern '%s' unsupported, using bggr",
        bayer_pattern_.c_str());
      bayer_pattern_ = "bggr";
    }

    rgb_out_ = output_encoding_ == "rgb8";
    if (!rgb_out_ && output_encoding_ != "bayer_rggb8") {
      RCLCPP_WARN(
        get_logger(), "unknown output_encoding '%s', falling back to rgb8",
        output_encoding_.c_str());
      rgb_out_ = true;
    }

    auto sub = create_sub_node(camera_name_);
    it_ = std::make_unique<image_transport::ImageTransport>(sub);
    // image_transport ignores the sub-node namespace — use explicit paths so
    // the topics always land on /<camera_name>/image_raw(+camera_info).
    const std::string base = "/" + camera_name_ + "/image_raw";
    if (use_sensor_data_qos_) {
      // image_transport (humble) cannot express best-effort; publish raw msgs
      raw_img_pub_ = sub->create_publisher<Image>(base, rclcpp::SensorDataQoS());
      raw_ci_pub_ = sub->create_publisher<CameraInfo>(
        "/" + camera_name_ + "/camera_info", rclcpp::SensorDataQoS());
    } else {
      cam_pub_ = it_->advertiseCamera(base, 10);
    }

    cinfo_ = std::make_unique<camera_info_manager::CameraInfoManager>(
      sub.get(), camera_name_, camera_info_url_);

    RCLCPP_INFO(
      get_logger(),
      "camera_name=%s frame=%s out=%s pattern=%s exposure=%.0fus qos=%s recover_script=%s",
      camera_name_.c_str(), frame_id_.c_str(),
      rgb_out_ ? (bayer_pattern_ == "bggr" ? "bgr8" : "rgb8") : ("bayer_" + bayer_pattern_ + "8").c_str(),
      bayer_pattern_.c_str(),
      exposure_time_us_, use_sensor_data_qos_ ? "sensor_data" : "reliable(10)",
      recover_script_.c_str());

    health_timer_ = create_wall_timer(std::chrono::seconds(1), [this] {healthTick();});

    // initial open; on failure the health tick keeps retrying (WAIT_DEVICE)
    if (openCamera()) {
      startGrabThread();
      state_ = State::STREAMING;
    } else {
      state_ = State::WAIT_DEVICE;
      wait_secs_ = 0;
    }
  }

  ~AravisCameraNode() override
  {
    running_ = false;
    if (grab_thread_.joinable()) {grab_thread_.join();}
    stopGrabThread();
    std::lock_guard<std::mutex> lk(dev_m_);
    closeCameraLocked();
  }

private:
  enum class State { STREAMING, REOPEN, USB_RECOVER, WAIT_DEVICE, COOLDOWN };

  // ---------- device handling (dev_m_ held; grab thread must be stopped) ----
  void closeCameraLocked()
  {
    if (stream_) {
      g_object_unref(stream_);
      stream_ = nullptr;
    }
    if (cam_) {
      arv_camera_stop_acquisition(cam_, nullptr);
      g_object_unref(cam_);
      cam_ = nullptr;
    }
  }

  bool openCamera()
  {
    std::lock_guard<std::mutex> lk(dev_m_);
    closeCameraLocked();

    GError * err = nullptr;
    cam_ = arv_camera_new(nullptr, &err);
    if (err || !cam_) {
      RCLCPP_WARN(
        get_logger(), "open failed: %s (camera busy or absent)",
        err ? err->message : "no device");
      g_clear_error(&err);
      return false;
    }
    arv_camera_set_pixel_format(cam_, ARV_PIXEL_FORMAT_BAYER_RG_8, &err);
    g_clear_error(&err);

    gint x0 = 0, y0 = 0, w = 0, h = 0;
    arv_camera_get_region(cam_, &x0, &y0, &w, &h, &err);
    g_clear_error(&err);
    if (w <= 0 || h <= 0) {
      RCLCPP_WARN(get_logger(), "get_region failed — reopening");
      closeCameraLocked();
      return false;
    }
    width_ = w;
    height_ = h;

    arv_camera_set_exposure_time_auto(cam_, ARV_AUTO_OFF, &err);
    g_clear_error(&err);
    arv_camera_set_exposure_time(cam_, exposure_time_us_, &err);
    if (err) {
      RCLCPP_WARN(get_logger(), "set_exposure_time: %s", err->message);
      g_clear_error(&err);
    }

    payload_ = arv_camera_get_payload(cam_, &err);
    g_clear_error(&err);

    stream_ = arv_camera_create_stream(cam_, nullptr, nullptr, &err);
    if (err || !stream_) {
      RCLCPP_WARN(get_logger(), "create_stream failed: %s", err ? err->message : "?");
      g_clear_error(&err);
      closeCameraLocked();
      return false;
    }
    for (int i = 0; i < 8; ++i) {
      arv_stream_push_buffer(stream_, arv_buffer_new(payload_, nullptr));
    }
    arv_camera_start_acquisition(cam_, &err);
    if (err) {
      RCLCPP_WARN(get_logger(), "start_acquisition: %s", err->message);
      g_clear_error(&err);
      closeCameraLocked();
      return false;
    }

    applyWhiteBalance();

    if (rgb_out_) {
      rgb_buf_.assign(static_cast<size_t>(w) * h * 3, 0);
    }

    ci_ = cinfo_->getCameraInfo();
    ci_.width = static_cast<uint32_t>(w);
    ci_.height = static_cast<uint32_t>(h);

    RCLCPP_INFO(
      get_logger(), "camera open: %dx%d, exposure %.0f us — streaming",
      w, h, exposure_time_us_);
    return true;
  }

  // ---------- white balance -------------------------------------------------
  // Sensor's raw Bayer output is heavily green-cast (R/G ≈ 0.60 measured).
  // The camera's ColorTemperatureAutoSel corrects incompletely and does not
  // show up in the gain registers (nondeterministic = perceived drift). Policy:
  // kill AutoSel, then per wb_mode:
  //   once   — execute camera one-shot WB (WBOnce), gains then stay locked
  //   manual — write wb_rgain/wb_ggain/wb_bgain
  //   off    — leave as-is
  // Called on EVERY open (incl. post-recovery) so color survives link deaths
  // (the camera MCU reboots on VBUS cycles and forgets its WB state).
  void applyWhiteBalance()
  {
    ArvDevice * dev = arv_camera_get_device(cam_);
    GError * err = nullptr;

    arv_device_set_boolean_feature_value(dev, "ColorTemperatureAutoSel", FALSE, &err);
    if (err) {
      RCLCPP_DEBUG(get_logger(), "ColorTemperatureAutoSel: %s", err->message);
      g_clear_error(&err);
    }

    if (wb_mode_ == "once") {
      arv_device_execute_command(dev, "WBOnce", &err);
      if (err) {
        RCLCPP_WARN(get_logger(), "WBOnce failed: %s", err->message);
        g_clear_error(&err);
      } else {
        std::this_thread::sleep_for(std::chrono::milliseconds(2500));  // WB settle
      }
    } else if (wb_mode_ == "manual") {
      arv_device_set_integer_feature_value(dev, "RGain", wb_rgain_, &err);
      g_clear_error(&err);
      arv_device_set_integer_feature_value(dev, "GGain", wb_ggain_, &err);
      g_clear_error(&err);
      arv_device_set_integer_feature_value(dev, "BGain", wb_bgain_, &err);
      g_clear_error(&err);
    }

    const gint r = arv_device_get_integer_feature_value(dev, "RGain", &err);
    g_clear_error(&err);
    const gint g = arv_device_get_integer_feature_value(dev, "GGain", &err);
    g_clear_error(&err);
    const gint b = arv_device_get_integer_feature_value(dev, "BGain", &err);
    g_clear_error(&err);
    RCLCPP_INFO(
      get_logger(), "white balance: mode=%s, gains R=%d G=%d B=%d",
      wb_mode_.c_str(), r, g, b);
  }

  // ---------- grab thread --------------------------------------------------
  void startGrabThread()
  {
    running_ = true;
    frames_ = 0;
    grab_thread_ = std::thread([this] {grabLoop();});
  }

  void stopGrabThread()
  {
    running_ = false;
    if (grab_thread_.joinable()) {grab_thread_.join();}
  }

  void grabLoop()
  {
    while (running_ && rclcpp::ok()) {
      ArvStream * st = nullptr;
      {
        std::lock_guard<std::mutex> lk(dev_m_);
        st = stream_;
      }
      if (!st) {
        std::this_thread::sleep_for(std::chrono::milliseconds(50));
        continue;
      }
      ArvBuffer * b = arv_stream_timeout_pop_buffer(st, 200000);  // 200 ms, µs
      if (!b) {continue;}
      if (arv_buffer_get_status(b) == ARV_BUFFER_STATUS_SUCCESS) {
        frames_++;
        publish(b);
      }
      arv_stream_push_buffer(st, b);
    }
  }

  void publish(ArvBuffer * b)
  {
    size_t sz = 0;
    const guint8 * d = reinterpret_cast<const guint8 *>(arv_buffer_get_data(b, &sz));

    Image img;
    img.header.stamp = now();
    img.header.frame_id = frame_id_;
    img.height = static_cast<uint32_t>(height_);
    img.width = static_cast<uint32_t>(width_);
    img.is_bigendian = false;

    if (rgb_out_) {
      // BGGR stream debayered with the RGGB site logic yields bytes in
      // [S00=B, G, S11=R] order — that IS bgr8, a standard ROS encoding.
      img.encoding = (bayer_pattern_ == "bggr") ? "bgr8" : "rgb8";
      img.step = static_cast<uint32_t>(width_) * 3;
      debayerRGGB(d, rgb_buf_.data());
      img.data.assign(rgb_buf_.begin(), rgb_buf_.end());
    } else {
      img.encoding = "bayer_" + bayer_pattern_ + "8";
      img.step = static_cast<uint32_t>(width_);
      img.data.assign(d, d + sz);
    }

    if (raw_img_pub_) {
      raw_img_pub_->publish(img);
      raw_ci_pub_->publish(ci_);
    } else {
      cam_pub_.publish(img, ci_);
    }
  }

  // RGGB nearest-neighbor debayer (same algorithm as ~/aravis/arv_grab.c)
  void debayerRGGB(const guint8 * src, guint8 * dst)
  {
    const int w = width_, h = height_;
    for (int y = 0; y < h; ++y) {
      const bool even_row = !(y & 1);
      for (int x = 0; x < w; ++x) {
        const bool even_col = !(x & 1);
        int r, g, b;
        const int xr = x + 1 < w ? x + 1 : x;
        const int xl = x > 0 ? x - 1 : x;
        const int yd = y + 1 < h ? y + 1 : y;
        const int yu = y > 0 ? y - 1 : y;
        if (even_row && even_col) {  // R
          r = src[y * w + x];
          g = (src[y * w + xr] + src[yd * w + x]) >> 1;
          b = src[yd * w + xr];
        } else if (even_row && !even_col) {  // G (row R)
          r = src[y * w + xl];
          g = src[y * w + x];
          b = src[yd * w + x];
        } else if (!even_row && even_col) {  // G (row B)
          r = src[yu * w + x];
          g = src[y * w + x];
          b = src[y * w + xr];
        } else {  // B
          r = src[yu * w + xl];
          g = (src[yu * w + x] + src[y * w + xl]) >> 1;
          b = src[y * w + x];
        }
        *dst++ = static_cast<guint8>(r > 255 ? 255 : r);
        *dst++ = static_cast<guint8>(g > 255 ? 255 : g);
        *dst++ = static_cast<guint8>(b > 255 ? 255 : b);
      }
    }
  }

  // ---------- recovery state machine (health tick, 1 Hz) --------------------
  bool devicePresent()
  {
    return std::system("lsusb 2>/dev/null | grep -q 'f622:d132'") == 0;
  }

  void healthTick()
  {
    switch (state_) {
      case State::STREAMING: {
          const auto f = frames_.load();
          if (f == last_frames_) {
            stall_secs_++;
          } else {
            stall_secs_ = 0;
            last_frames_ = f;
            backoff_s_ = 1;
          }
          if (stall_secs_ >= static_cast<int>(stall_seconds_)) {
            RCLCPP_WARN(
              get_logger(), "[RECOVER] no frames for %d s -> REOPEN (level 1)",
              stall_secs_);
            state_ = State::REOPEN;
            open_fails_ = 0;
          }
          break;
        }
      case State::REOPEN: {
          stopGrabThread();
          if (openCamera()) {
            startGrabThread();
            frames_ = 0;
            last_frames_ = 0;
            stall_secs_ = 0;
            open_fails_ = 0;
            state_ = State::STREAMING;
            RCLCPP_WARN(get_logger(), "[RECOVER] REOPEN ok — streaming again");
          } else if (++open_fails_ >= 2) {
            RCLCPP_WARN(get_logger(), "[RECOVER] REOPEN failed twice -> USB_RECOVER");
            state_ = State::USB_RECOVER;
          }
          break;
        }
      case State::USB_RECOVER: {
          if (!recover_busy_) {
            recover_busy_ = true;
            RCLCPP_WARN(get_logger(), "[RECOVER] running %s", recover_script_.c_str());
            std::thread(
              [this] {
                const std::string cmd = "timeout 120 " + recover_script_;
                recover_rc_ = std::system(cmd.c_str());
                recover_done_ = true;
              }).detach();
          }
          if (recover_done_) {
            recover_busy_ = false;
            recover_done_ = false;
            if (recover_rc_ == 3) {
              RCLCPP_WARN(
                get_logger(),
                "[RECOVER] camera held by another process — skipping power cycle, "
                "will keep retrying");
              state_ = State::COOLDOWN;
              cooldown_ = backoff_s_;
            } else {
              state_ = State::WAIT_DEVICE;
              wait_secs_ = 0;
            }
          }
          break;
        }
      case State::WAIT_DEVICE: {
          wait_secs_++;
          if (devicePresent()) {
            RCLCPP_WARN(get_logger(), "[RECOVER] device back on bus -> REOPEN");
            open_fails_ = 0;
            state_ = State::REOPEN;
          } else if (wait_secs_ > 60) {
            RCLCPP_ERROR(
              get_logger(),
              "[RECOVER] device absent >60 s after power cycle — "
              "check cable / PHYSICAL REPLUG");
            wait_secs_ = 0;
          }
          break;
        }
      case State::COOLDOWN: {
          if (--cooldown_ <= 0) {
            backoff_s_ = std::min(backoff_s_ * 2, 30);
            RCLCPP_WARN(get_logger(), "[RECOVER] retrying USB_RECOVER (backoff %d s)",
              backoff_s_);
            state_ = State::USB_RECOVER;
          }
          break;
        }
    }
  }

  // parameters
  std::string camera_name_, frame_id_, camera_info_url_, output_encoding_;
  std::string recover_script_;
  std::string wb_mode_;
  int wb_rgain_{100}, wb_ggain_{100}, wb_bgain_{100};
  std::string bayer_pattern_;
  double exposure_time_us_{10000.0};
  double stall_seconds_{5.0};
  bool use_sensor_data_qos_{false};
  bool rgb_out_{true};

  // ros
  rclcpp::Node::SharedPtr sub_;
  std::unique_ptr<image_transport::ImageTransport> it_;
  image_transport::CameraPublisher cam_pub_;
  rclcpp::Publisher<Image>::SharedPtr raw_img_pub_;
  rclcpp::Publisher<CameraInfo>::SharedPtr raw_ci_pub_;
  std::unique_ptr<camera_info_manager::CameraInfoManager> cinfo_;
  rclcpp::TimerBase::SharedPtr health_timer_;

  // aravis device (guarded by dev_m_, grab thread must be stopped when touched)
  std::mutex dev_m_;
  ArvCamera * cam_{nullptr};
  ArvStream * stream_{nullptr};
  size_t payload_{0};
  int width_{0}, height_{0};
  std::vector<guint8> rgb_buf_;
  CameraInfo ci_;

  // grab thread
  std::thread grab_thread_;
  std::atomic<bool> running_{false};
  std::atomic<guint64> frames_{0};

  // recovery state
  State state_{State::STREAMING};
  guint64 last_frames_{0};
  int stall_secs_{0};
  int open_fails_{0};
  int wait_secs_{0};
  int backoff_s_{1};
  int cooldown_{0};
  std::atomic<bool> recover_busy_{false};
  std::atomic<bool> recover_done_{false};
  int recover_rc_{0};
};

}  // namespace sua_aravis_camera

int main(int argc, char ** argv)
{
  rclcpp::init(argc, argv);
  rclcpp::spin(std::make_shared<sua_aravis_camera::AravisCameraNode>());
  rclcpp::shutdown();
  return 0;
}
