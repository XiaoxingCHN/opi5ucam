cmake_minimum_required(VERSION 3.8)
project(sua_aravis_camera)

if(NOT CMAKE_CXX_STANDARD)
  set(CMAKE_CXX_STANDARD 17)
endif()

find_package(ament_cmake REQUIRED)
find_package(rclcpp REQUIRED)
find_package(sensor_msgs REQUIRED)
find_package(image_transport REQUIRED)
find_package(camera_info_manager REQUIRED)
find_package(PkgConfig REQUIRED)

# Aravis 0.8.31 is installed from source under /usr/local (aarch64 triplet).
set(ENV{PKG_CONFIG_PATH} "/usr/local/lib/aarch64-linux-gnu/pkgconfig:$ENV{PKG_CONFIG_PATH}")
pkg_check_modules(ARAVIS REQUIRED aravis-0.8)

add_executable(aravis_camera_node src/aravis_camera_node.cpp)
ament_target_dependencies(aravis_camera_node
  rclcpp sensor_msgs image_transport camera_info_manager)
target_include_directories(aravis_camera_node PRIVATE ${ARAVIS_INCLUDE_DIRS})
target_link_directories(aravis_camera_node PRIVATE ${ARAVIS_LIBRARY_DIRS})
target_link_libraries(aravis_camera_node ${ARAVIS_LIBRARIES})

install(TARGETS aravis_camera_node
  DESTINATION lib/${PROJECT_NAME})
install(PROGRAMS scripts/camera_monitor.py
  DESTINATION lib/${PROJECT_NAME})
install(DIRECTORY launch config
  DESTINATION share/${PROJECT_NAME})

ament_package()
