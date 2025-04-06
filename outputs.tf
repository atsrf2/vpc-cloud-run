
output "vpc_name" {
  value = google_compute_network.vpc.name
}

output "cloud_run_a_url" {
  value = google_cloud_run_v2_service.cloudrun_a.uri
}

output "cloud_run_b_url" {
  value = google_cloud_run_v2_service.cloudrun_b.uri
}
