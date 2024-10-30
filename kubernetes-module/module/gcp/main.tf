provider "google" {
  project = "your-google-project-id"
  region  = "us-central1"
}

variable "enabled" {
  type    = bool
  default = false 
}
resource "google_compute_disk" "app_volume" {
  count = var.enabled ? 1 : 0
  name  = "app-volume"
  size  = 1             
  zone  = "us-central1-a"  
  type  = "pd-standard"
}

output "volume" {
  value = [for volume in google_compute_disk.app_volume : volume.name]
}