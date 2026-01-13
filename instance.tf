# -----------------------------
#      EC2 INSTANCES GROUP
# -----------------------------
resource "aws_key_pair" "ubuntu" {
  depends_on = [aws_nat_gateway.nat]
  key_name   = "ubuntu"
  public_key = file("~/.ssh/id_rsa.pub") # replace with your actual public key path
}

resource "aws_launch_template" "asg_lt" {

  depends_on = [aws_key_pair.ubuntu]
  name_prefix   = "asg-lt-"
  image_id      = "ami-0345dd2cef523536e" # Amazon Ubuntu (us-west-2)
  instance_type = "t2.medium"
  key_name      = "ubuntu" # change this

  vpc_security_group_ids = [aws_security_group.asg_sg.id]

  user_data = base64encode(<<EOF
#!/bin/bash
apt update -y
apt install -y apache2 php php-mysql wget unzip curl
systemctl enable apache2
systemctl start apache2

# Download WordPress
cd /var/www/html
wget https://wordpress.org/latest.zip
unzip latest.zip
mv wordpress/* .
rm -rf wordpress latest.zip

# Permissions
chown -R www-data:www-data /var/www/html
chmod -R 755 /var/www/html

# Configure wp-config.php
cat > /var/www/html/wp-config.php <<EOC
<?php
define('DB_NAME', '${var.db_name}');
define('DB_USER', '${var.db_username}');
define('DB_PASSWORD', '${var.db_password}');
define('DB_HOST', '${aws_db_instance.wordpress.address}');
define('DB_CHARSET', 'utf8');
define('DB_COLLATE', '');
\$table_prefix = 'wp_';
define('WP_DEBUG', false);
if ( !defined('ABSPATH') )
    define('ABSPATH', dirname(__FILE__) . '/');
require_once(ABSPATH . 'wp-settings.php');
EOC

systemctl restart apache2
EOF
  )

  # ---- Add 100GB disk ----
  block_device_mappings {
    device_name = "/dev/sda1"  # Root volume
    ebs {
      volume_size = 100       # 100 GB
      volume_type = "gp3"     # General Purpose SSD
      delete_on_termination = true
    }
  }

  tag_specifications {
    resource_type = "instance"

    tags = {
      Name = "asg-instance"
    }
  }
}

# -----------------------------
#       EC2 AUTOSCALING
# -----------------------------
resource "aws_autoscaling_group" "asg" {
  depends_on = [aws_launch_template.asg_lt]
  name             = "app-asg"
  min_size         = 1
  max_size         = 7
  desired_capacity = 2

  vpc_zone_identifier = aws_subnet.public[*].id

  launch_template {
    id      = aws_launch_template.asg_lt.id
    version = "$Latest"
  }

  health_check_type         = "EC2"
  health_check_grace_period = 300

  tag {
    key                 = "Name"
    value               = "asg-instance"
    propagate_at_launch = true
  }
}

# -----------------------------
# CLOUDWATCH ALARMS FOR SCALING
# -----------------------------
resource "aws_autoscaling_policy" "scale_up" {
  name                   = "scale-up"
  autoscaling_group_name = aws_autoscaling_group.asg.name
  adjustment_type        = "ChangeInCapacity"
  scaling_adjustment     = 1
  cooldown               = 300
}

resource "aws_autoscaling_policy" "scale_down" {
  name                   = "scale-down"
  autoscaling_group_name = aws_autoscaling_group.asg.name
  adjustment_type        = "ChangeInCapacity"
  scaling_adjustment     = -1
  cooldown               = 300
}

resource "aws_cloudwatch_metric_alarm" "cpu_high" {
  alarm_name          = "cpu-high"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "CPUUtilization"
  namespace           = "AWS/EC2"
  period              = 60
  statistic           = "Average"
  threshold           = 70
  alarm_actions       = [aws_autoscaling_policy.scale_up.arn]
  dimensions = {
    AutoScalingGroupName = aws_autoscaling_group.asg.name
  }
}

resource "aws_cloudwatch_metric_alarm" "cpu_low" {
  alarm_name          = "cpu-low"
  comparison_operator = "LessThanThreshold"
  evaluation_periods  = 2
  metric_name         = "CPUUtilization"
  namespace           = "AWS/EC2"
  period              = 60
  statistic           = "Average"
  threshold           = 20
  alarm_actions       = [aws_autoscaling_policy.scale_down.arn]
  dimensions = {
    AutoScalingGroupName = aws_autoscaling_group.asg.name
  }
}

