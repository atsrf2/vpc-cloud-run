
terraform {
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 5.0"
    }
  }
}

provider "google" {
  project = var.project_id
  region  = var.region_a
}

resource "google_compute_network" "vpc" {
  name                    = var.vpc_name
  auto_create_subnetworks = false
}

resource "google_compute_subnetwork" "subnet_a" {
  name          = var.subnet_a
  ip_cidr_range = "10.10.0.0/24"
  region        = var.region_a
  network       = google_compute_network.vpc.id
  purpose       = "PRIVATE"
  role          = "ACTIVE"
}

resource "google_compute_subnetwork" "subnet_b" {
  name          = var.subnet_b
  ip_cidr_range = "10.20.0.0/24"
  region        = var.region_b
  network       = google_compute_network.vpc.id
  purpose       = "PRIVATE"
  role          = "ACTIVE"
}

resource "google_vpc_access_connector" "connector_a" {
  name          = "connector-a"
  region        = var.region_a
  network       = google_compute_network.vpc.name
  ip_cidr_range = "10.8.0.0/28"
}

resource "google_vpc_access_connector" "connector_b" {
  name          = "connector-b"
  region        = var.region_b
  network       = google_compute_network.vpc.name
  ip_cidr_range = "10.9.0.0/28"
}

resource "google_cloud_run_v2_service" "cloudrun_a" {
  name     = var.cloud_run_name_a
  location = var.region_a
  ingress  = "INTERNAL"
  template {
    containers {
      image = "gcr.io/cloudrun/hello"
    }
    vpc_access {
      connector = google_vpc_access_connector.connector_a.name
      egress = "ALL_TRAFFIC"
    }
  }
}

resource "google_cloud_run_v2_service" "cloudrun_b" {
  name     = var.cloud_run_name_b
  location = var.region_b
  ingress  = "INTERNAL"
  template {
    containers {
      image = "gcr.io/cloudrun/hello"
    }
    vpc_access {
      connector = google_vpc_access_connector.connector_b.name
      egress = "ALL_TRAFFIC"
    }
  }
}

resource "google_compute_region_network_endpoint_group" "neg_a" {
  name                  = "neg-a"
  network_endpoint_type = "SERVERLESS"
  region                = var.region_a
  cloud_run {
    service = google_cloud_run_v2_service.cloudrun_a.name
  }
}

resource "google_compute_region_network_endpoint_group" "neg_b" {
  name                  = "neg-b"
  network_endpoint_type = "SERVERLESS"
  region                = var.region_b
  cloud_run {
    service = google_cloud_run_v2_service.cloudrun_b.name
  }
}

resource "google_compute_health_check" "hc" {
  name               = "basic-hc"
  check_interval_sec = 5
  timeout_sec        = 5
  http_health_check {
    port_specification = "USE_SERVING_PORT"
    request_path       = "/"
  }
}

resource "google_compute_backend_service" "backend_service" {
  name                            = "cloudrun-ilb-backend"
  load_balancing_scheme           = "INTERNAL_MANAGED"
  protocol                        = "HTTP"
  port_name                       = "http"
  health_checks                   = [google_compute_health_check.hc.id]
  backends = [
    {
      group = google_compute_region_network_endpoint_group.neg_a.id
    },
    {
      group = google_compute_region_network_endpoint_group.neg_b.id
    }
  ]
}

resource "google_compute_url_map" "url_map" {
  name            = "cloudrun-ilb-url-map"
  default_service = google_compute_backend_service.backend_service.id
}

resource "google_compute_target_http_proxy" "http_proxy" {
  name   = "cloudrun-ilb-proxy"
  url_map = google_compute_url_map.url_map.id
}

resource "google_compute_forwarding_rule" "forwarding_rule" {
  name                  = "cloudrun-ilb-fw-rule"
  load_balancing_scheme = "INTERNAL_MANAGED"
  IP_protocol           = "TCP"
  ports                 = ["80"]
  network               = google_compute_network.vpc.id
  subnetwork            = google_compute_subnetwork.subnet_a.id
  backend_service       = google_compute_backend_service.backend_service.id
  region                = var.region_a
  ip_address            = "10.10.0.5"
}

resource "google_project_iam_member" "cloud_run_invoker" {
  project = var.project_id
  role    = "roles/run.invoker"
  member  = "allUsers"
}
