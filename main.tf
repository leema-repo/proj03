terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = "ap-south-1"
}

############################
# DATA SOURCES
############################

# Use provided VPC
data "aws_vpc" "selected" {
  id = "vpc-0959a04c29aea8e9a"
}

# Get all subnets in the VPC
data "aws_subnets" "all" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.selected.id]
  }
}

# Get details of each subnet
data "aws_subnet" "details" {
  for_each = toset(data.aws_subnets.all.ids)
  id       = each.value
}

# Filter public subnets
locals {
  public_subnets = [
    for subnet in data.aws_subnet.details :
    subnet.id if subnet.map_public_ip_on_launch
  ]
}

# Latest Ubuntu 22.04 AMI
data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"] # Canonical

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*"]
  }
}

############################
# SECURITY GROUPS
############################

# ALB Security Group
resource "aws_security_group" "alb_sg" {
  name   = "alb-sg"
  vpc_id = data.aws_vpc.selected.id

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# EC2 Security Group
resource "aws_security_group" "ec2_sg" {
  name   = "ec2-web-sg"
  vpc_id = data.aws_vpc.selected.id

  # Allow traffic only from ALB
  ingress {
    from_port       = 80
    to_port         = 80
    protocol        = "tcp"
    security_groups = [aws_security_group.alb_sg.id]
  }

  # SSH (demo purpose)
  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

############################
# LAUNCH TEMPLATE
############################

resource "aws_launch_template" "web_lt" {
  name_prefix   = "apache-lt-"
  image_id      = data.aws_ami.ubuntu.id
  instance_type = "t3.micro"
  key_name      = "asia-kp-tf-01"

  vpc_security_group_ids = [aws_security_group.ec2_sg.id]

  user_data = base64encode(<<-EOF
    #!/bin/bash
    apt update -y
    apt install apache2 unzip wget -y
    systemctl start apache2
    systemctl enable apache2

    cd /tmp
    wget https://www.tooplate.com/zip-templates/2094_mason.zip
    unzip 2094_mason.zip

    rm -rf /var/www/html/*
    cp -r 2094_mason/* /var/www/html/

    chown -R www-data:www-data /var/www/html
    chmod -R 755 /var/www/html

    systemctl restart apache2
  EOF
  )
}

############################
# APPLICATION LOAD BALANCER
############################

resource "aws_lb" "app_alb" {
  name               = "apache-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb_sg.id]

  # ALB requires at least 2 subnets in different AZs
  subnets = slice(local.public_subnets, 0, 2)
}

resource "aws_lb_target_group" "app_tg" {
  name     = "apache-tg"
  port     = 80
  protocol = "HTTP"
  vpc_id   = data.aws_vpc.selected.id

  health_check {
    path                = "/"
    interval            = 30
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 2
  }
}

resource "aws_lb_listener" "http_listener" {
  load_balancer_arn = aws_lb.app_alb.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.app_tg.arn
  }
}

############################
# AUTO SCALING GROUP
############################

resource "aws_autoscaling_group" "web_asg" {
  min_size            = 1
  max_size            = 3
  desired_capacity    = 2
  vpc_zone_identifier = slice(local.public_subnets, 0, 2)
  target_group_arns   = [aws_lb_target_group.app_tg.arn]

  launch_template {
    id      = aws_launch_template.web_lt.id
    version = "$Latest"
  }

  tag {
    key                 = "Name"
    value               = "apache-asg-instance"
    propagate_at_launch = true
  }
}
