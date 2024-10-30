module "app_deploy" {
  source          = "./module/kubernetes_job"   #Required
  app_path        = "./my/path/toapp"           #Required
  cpu_limit       = 2                           #Required
  build_command   = "my build command"          #Optional
  run_command     = "my run command"            #Optional
  workdir         = "/usr/src/app"              #Optional
  custom_image    = "my-custom-image"           #Optional
  kubeconfig_path = "my-kubeconfig-path"        #Optional
}
