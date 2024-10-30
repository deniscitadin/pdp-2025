variable "custom_image" {
  description = "Customized image for use in the container. Ignores automatic image selection."
  type        = string
  default     = null
}


variable "app_path" {
  description = "Application path on the local file system."
  type        = string
}

variable "kubeconfig_path" {
  description = "kubeconfig file path. If not provided, uses the default in ~/.kube/config"
  type        = string
  default     = ""
}

variable "cpu_limit" {
  description = "Number of CPUs for the container."
  type        = number
  default     = 1
}

variable "build_command" {
  description = "Compile command (optional)."
  type        = string
}

variable "run_command" {
  description = "Execute command (optional)."
  type        = string
}

variable "workdir" {
  description = "The working directory within the container."
  type        = string
  default     = "/usr/src/app" 
}

variable "cloud_provider" {
  description = "Cloud provider type. Options: aws, gcp, azure, or private. Auto-detected if not set."
  type        = string
  default     = null
}

provider "kubernetes" {
  config_path = local.kubeconfig
}
data "kubernetes_nodes" "all" {}

locals {
  container_image = var.custom_image != null ? var.custom_image : lookup(local.images, local.app_extension, local.images.default)
  app_extension = regex(".*\\.(.*)$", var.app_path)[0]
  images = {
    "c"  = "gcc:latest"
    "py" = "python:3.9"
    "js" = "node:14"
    "go" = "golang:1.16"
    "rb" = "ruby:2.7"
    "default" = "ubuntu:latest"
  }
  kubeconfig = var.kubeconfig_path != "" ? var.kubeconfig_path : "${pathexpand("~/.kube/config")}"
  storage_class = lookup({
    aws     = "gp2",
    gcp     = "standard",
    azure   = "default",
    private = "custom-storage-class"
  }, local.detected_cloud_provider, null)
  is_aws = can(regex("eks\\.amazonaws\\.com", lower(data.local_file.kubeconfig.content)))
  is_gcp = can(regex("gke\\.googleapis\\.com", lower(data.local_file.kubeconfig.content)))
  is_azure = can(regex("aks\\.azure\\.com", lower(data.local_file.kubeconfig.content)))
  
  detected_cloud_provider = var.cloud_provider != null ? var.cloud_provider : local.is_aws ? "aws" : local.is_gcp ? "gcp" : local.is_azure ? "azure" : "private"
  cpu_limit_millicores = var.cpu_limit * 1000

  node_resources = [
    for node in data.kubernetes_nodes.all.nodes : {
      name                     = node.metadata[0].name
      allocatable_cpu_millicores = tonumber(replace(node.status[0].allocatable["cpu"], "m", ""))
    }
  ]

  suitable_node = try(
    [for node in local.node_resources : node if node.allocatable_cpu_millicores >= local.cpu_limit_millicores][0],
    null
  )
}

output "node_selection_message" {
  value = local.suitable_node != null ? "Node '${local.suitable_node.name}' selected with available CPU: ${local.suitable_node.allocatable_cpu_millicores} millicores." : "Requested ${var.cpu_limit} CPUs (${local.cpu_limit_millicores} millicores), but no node has enough resources. Job will run with maximum available CPU: ${max(local.node_resources[*].allocatable_cpu_millicores) / 1000}."
}

data "local_file" "kubeconfig" {
  filename = local.kubeconfig
}

provider "aws" {
  region = "us-east-1"
}

module "aws" {
  source = "../aws"
  providers = {
    aws = aws
  }
  enabled = local.detected_cloud_provider == "aws" ? true : false
}

module "google_resources" {
  source = "../gcp"
  enabled = local.detected_cloud_provider == "google" ? true : false
}

module "azure_resources" {
  source = "../azure"
  enabled = local.detected_cloud_provider == "azure" ? true : false
}

resource "kubernetes_persistent_volume" "app_pv" {
  count = var.build_command != "" && var.custom_image == null ? 1 : 0

  metadata {
    name = "app-pv2"
  }
  
  spec {
    capacity = {
      storage = "1Gi"
    }
    access_modes = ["ReadWriteMany"]
    persistent_volume_reclaim_policy = "Retain"
    storage_class_name = local.storage_class

    dynamic "persistent_volume_source" {
      for_each = local.detected_cloud_provider == "aws" ? [1] : []
      content {
        csi {
          driver = "efs.csi.aws.com"
          volume_handle = module.aws.volume  
        }
      }
    }

    dynamic "persistent_volume_source" {
      for_each = local.detected_cloud_provider == "gcp" ? [1] : []
      content {
        csi {
          driver = "pd.csi.storage.gke.io"
          volume_handle = module.gcp.outputs.volume  
        }
      }
    }

    dynamic "persistent_volume_source" {
      for_each = local.detected_cloud_provider == "azure" ? [1] : []
      content {
        csi {
          driver = "disk.csi.azure.com"
          volume_handle = module.azure.outputs.volume  
        }
      }
    }
  }
}

resource "kubernetes_persistent_volume_claim" "app_pvc" {
  count = var.build_command != "" && var.custom_image == null ? 1 : 0

  metadata {
    name = "app-volume-claim2"
  }

  spec {
    access_modes = ["ReadWriteMany"]
    storage_class_name = local.storage_class
    resources {
      requests = {
        storage = "1Gi"
      }
    }
    volume_name = kubernetes_persistent_volume.app_pv[count.index].metadata[0].name
  }
}

resource "kubernetes_config_map" "app_source" {
  metadata {
    name = "app-source"
  }

  data = {
    "${basename(var.app_path)}" = file(var.app_path)
  }
}

resource "kubernetes_job" "build_job" {
  count = var.build_command != "" && var.custom_image == null ? 1 : 0

  metadata {
    name = "app-build-job"
  }

  spec {
    template {
      metadata {
        labels = {
          job = "app-build-job"
        }
      }

      spec {
        container {
          name  = "build-container"
          image = local.container_image

          working_dir = var.workdir

          volume_mount {
            name       = "app-source-volume"
            mount_path = "${var.workdir}/${basename(var.app_path)}"
            sub_path   = "${basename(var.app_path)}"
          }

          volume_mount {
            name       = "app-pvc-volume"
            mount_path = var.workdir
          }

          command = ["/bin/sh", "-c", var.build_command]
        }

        volume {
          name = "app-source-volume"
          config_map {
            name = kubernetes_config_map.app_source.metadata[0].name
          }
        }

        volume {
          name = "app-pvc-volume"
          persistent_volume_claim {
            claim_name = kubernetes_persistent_volume_claim.app_pvc[0].metadata[0].name
          }
        }

        restart_policy = "OnFailure"
      }
    }
  }
}

resource "kubernetes_job" "run_job" {
  metadata {
    name = "app-run-job"
  }

  spec {
    template {
      metadata {
        labels = {
          job = "app-run-job"
        }
      }

      spec {
        node_selector = local.suitable_node != null ? {
          "kubernetes.io/hostname" = local.suitable_node.name
        } : {}

        container {
          name  = "run-container"
          image = local.container_image

          working_dir = var.workdir

          dynamic "volume_mount" {
            for_each = var.custom_image == null ? [1] : []
            content {
              name       = "app-pvc-volume"
              mount_path = var.workdir
            }
          }

          resources {
            limits = {
              cpu = local.suitable_node != null ? "${var.cpu_limit}" : "${max(local.node_resources[*].allocatable_cpu_millicores) / 1000}"
            }
          }

          command = ["/bin/sh", "-c", var.run_command]
        }

        dynamic "volume" {
          for_each = var.custom_image == null ? [1] : []
          content {
            name = "app-pvc-volume"
            persistent_volume_claim {
              claim_name = kubernetes_persistent_volume_claim.app_pvc[0].metadata[0].name
            }
          }
        }

        restart_policy = "Never"
      }
    }
    backoff_limit = 1
  }
}

