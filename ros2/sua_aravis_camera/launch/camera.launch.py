import os
from ament_index_python.packages import get_package_share_directory
from launch import LaunchDescription
from launch.actions import DeclareLaunchArgument
from launch.conditions import IfCondition
from launch.substitutions import LaunchConfiguration
from launch_ros.actions import Node


def generate_launch_description():
    pkg_share = get_package_share_directory('sua_aravis_camera')
    default_params = os.path.join(pkg_share, 'config', 'default.yaml')
    rviz_config = os.path.join(pkg_share, 'config', 'view_camera.rviz')

    rviz_arg = DeclareLaunchArgument(
        'rviz', default_value='false',
        description='Start rviz2 with the bundled image viewer config')
    params_arg = DeclareLaunchArgument(
        'params', default_value=default_params,
        description='Node parameter yaml file')
    monitor_arg = DeclareLaunchArgument(
        'monitor', default_value='false',
        description='Start the GTK status/fps monitor window')

    camera_node = Node(
        package='sua_aravis_camera',
        executable='aravis_camera_node',
        name='aravis_camera_node',
        output='screen',
        parameters=[LaunchConfiguration('params')],
    )

    rviz_node = Node(
        package='rviz2',
        executable='rviz2',
        name='rviz2',
        output='log',
        arguments=['-d', rviz_config],
        condition=IfCondition(LaunchConfiguration('rviz')),
    )

    monitor_node = Node(
        package='sua_aravis_camera',
        executable='camera_monitor.py',
        name='camera_monitor',
        output='log',
        condition=IfCondition(LaunchConfiguration('monitor')),
        additional_env={'GDK_BACKEND': 'x11'},
    )

    return LaunchDescription(
        [rviz_arg, params_arg, monitor_arg, camera_node, rviz_node, monitor_node])
