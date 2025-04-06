
#important for managing dependencies and configurations in your Terraform setup# ------------------------------------------------------------------------------

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

#vpc virtual private cloud

resource "google_compute_network" "vpc" {
  name                    = var.vpc_name
  auto_create_subnetworks = false
}

#subnets-code # ------------------------------------------------------------------------------

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

#VPC-access-connector # ------------------------------------------------------------------------------
# VPC Access Connector
#
# A VPC Access Connector allows serverless services like:
#   - Cloud Run
#   - Cloud Functions
#   - App Engine
# to send traffic into a VPC network using private IP.
#
# This is essential when Cloud Run needs to connect to:
#   - Cloud SQL (using private IP)
#   - Internal Load Balancer (ILB)
#   - VM-based internal APIs
#   - Memorystore (Redis)
#   - Any other internal/private services inside the VPC
#
# Without this, serverless services can only access public internet resources.
#--------------

resource "google_vpc_access_connector" "connector_a" {
  name          = "connector-a"                        # Name of the connector
  region        = var.region_a                         # Must match the region of Cloud Run service
  network       = google_compute_network.vpc.name      # VPC network to connect to
  ip_cidr_range = "10.8.0.0/28"                        # Reserved IP range for this connector
}


resource "google_vpc_access_connector" "connector_b" {
  name          = "connector-b"
  region        = var.region_b
  network       = google_compute_network.vpc.name
  ip_cidr_range = "10.9.0.0/28"
}

#cloud-run A & B # ------------------------------------------------------------------------------

# - Deploys a Cloud Run (v2) service with internal-only access
# - Connects to VPC using VPC Access Connector A
# - Sends all egress traffic through the connector (required for private ILB)
# ----------

resource "google_cloud_run_v2_service" "cloudrun_a" {
  name     = var.cloud_run_name_a                                                  # Service name from variable
  location = var.region_a                                                         # Must match connector and NEG region
  ingress  = "INTERNAL"                                                           # Restrict to internal requests only

  template {
    containers {
      image = "gcr.io/cloudrun/hello"                                             # Sample container image (replace in prod)
    }

    vpc_access {
      connector = google_vpc_access_connector.connector_a.name                      # VPC connector for region A
      egress    = "ALL_TRAFFIC"                                                     # Send all traffic via VPC
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

#NEG network endpoint grpup # ------------------------------------------------------------------------------

# Serverless NEG for Cloud Run Service A (Region A)
#
# - Creates a Serverless Network Endpoint Group (NEG)
# - Acts as a target for Internal Load Balancer to reach Cloud Run
# - Required to connect ILB with Cloud Run (since it's serverless)
# -------------

resource "google_compute_region_network_endpoint_group" "neg_a" {
  name                  = "neg-a"                                        # Unique name for the NEG
  network_endpoint_type = "SERVERLESS"                                  # Indicates this is for serverless (Cloud Run)
  region                = var.region_a                                  # Must match the region of the Cloud Run service
       
  cloud_run {
    service = google_cloud_run_v2_service.cloudrun_a.name # The Cloud Run service to attach
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

#health check # ------------------------------------------------------------------------------

# Health Check for Internal Load Balancer
#
# - Basic HTTP health check used by Backend Service
# - Helps Load Balancer determine if Cloud Run services (via NEGs) are healthy
# - Uses "/" as request path and default serving port of Cloud Run
--------------


resource "google_compute_health_check" "hc" {
  name               = "basic-hc"             # Name of the health check
  check_interval_sec = 5                     # Check every 5 seconds
  timeout_sec        = 5                     # Fail if no response within 5 seconds

  http_health_check {
    port_specification = "USE_SERVING_PORT"  # Automatically use port exposed by Cloud Run
    request_path       = "/"                 # Path to check — adjust if your app uses something like /healthz
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

#backend service # ------------------------------------------------------------------------------
# Backend Service for Internal HTTP Load Balancer
# A Backend Service acts like the "brain" of a Google Cloud Load Balancer.
# - Connects the Load Balancer to Cloud Run services (via Serverless NEGs)
# - Handles routing, health checks, and traffic balancing across regions
# -----------


resource "google_compute_backend_service" "backend_service" {
  name                  = "cloudrun-ilb-backend"        # Name for the backend service
  load_balancing_scheme = "INTERNAL_MANAGED"            # Specifies internal HTTP(S) Load Balancer
  protocol              = "HTTP"                        # Protocol used between LB and backends
  port_name             = "http"                        # Port label (used in forwarding rule)
  health_checks         = [google_compute_health_check.hc.id]  # Attach the health check

  backends = [
    {
      group = google_compute_region_network_endpoint_group.neg_a.id                          # Cloud Run NEG in Region A
    },
    {
      group = google_compute_region_network_endpoint_group.neg_b.id                          # Cloud Run NEG in Region B
    }
  ]
}

#url map # ------------------------------------------------------------------------------

# URL Map for Internal Load Balancer
#
# - Routes incoming requests to the appropriate backend service
# - Currently uses a default route (no path-based or host-based routing)
# -----------

resource "google_compute_url_map" "url_map" {
  name            = "cloudrun-ilb-url-map"                                                   # Unique name for the URL map
  default_service = google_compute_backend_service.backend_service.id                          # Default backend to route all traffic
}




#http proxy # ------------------------------------------------------------------------------

# Target HTTP Proxy for Internal Load Balancer
#
# - Acts as the entry point for HTTP requests
# - Forwards incoming traffic based on URL map rules

# Target HTTP Proxy Explanation:
#
# - Receives incoming HTTP requests from the forwarding rule (created next)
# - Forwards the requests to the URL Map
# - URL Map then routes traffic based on:
#     • Path (e.g., /api/*)
#     • Host (e.g., api.example.com)
#
# Traffic Flow:
# Client → Forwarding Rule → Target HTTP Proxy → URL Map → Backend Service → Cloud Run

# -----------

resource "google_compute_target_http_proxy" "http_proxy" {
  name    = "cloudrun-ilb-proxy"                                            # Name of the proxy
  url_map = google_compute_url_map.url_map.id                               # Attach URL map for routing logic
}



#forwarding rule # ------------------------------------------------------------------------------

# Forwarding Rule for Internal Load Balancer
#
# - Listens for internal TCP (HTTP) traffic on port 80
# - Routes traffic to the backend service via target proxy & URL map
# - Binds to a specific internal IP in subnet_a for internal access
# --------------

resource "google_compute_forwarding_rule" "forwarding_rule" {
  name                  = "cloudrun-ilb-fw-rule"                                   # Name of the forwarding rule
  load_balancing_scheme = "INTERNAL_MANAGED"                                       # Internal HTTP(S) Load Balancer
  IP_protocol           = "TCP"                                                    # Protocol to listen on (TCP required for HTTP)
  ports                 = ["80"]                                                   # Port where LB will receive traffic
  network               = google_compute_network.vpc.id                            # VPC network where the ILB lives
  subnetwork            = google_compute_subnetwork.subnet_a.id                          # Subnet for the internal IP
  backend_service       = google_compute_backend_service.backend_service.id                          # Final destination of traffic
  region                = var.region_a                                             # Region of the ILB (same as subnet)
  ip_address            = "10.10.0.5"                                              # Reserved internal IP to expose the ILB
}

#iam member # ------------------------------------------------------------------------------

resource "google_project_iam_member" "cloud_run_invoker" {
  project = var.project_id
  role    = "roles/run.invoker"
  member  = "allUsers"
}
