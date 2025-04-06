
variable "project_id" {}
variable "region_a" {}
variable "region_b" {}
variable "vpc_name" {
  default = "cloudrun-vpc"
}
variable "subnet_a" {
  default = "subnet-a"
}
variable "subnet_b" {
  default = "subnet-b"
}
variable "cloud_run_name_a" {
  default = "service-a"
}
variable "cloud_run_name_b" {
  default = "service-b"
}
