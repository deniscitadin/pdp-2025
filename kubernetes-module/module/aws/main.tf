variable "enabled" {
  type    = bool
  default = false  
}
resource "aws_efs_file_system" "this" {
  count = var.enabled == true ? 1 : 0
  creation_token = "efs"
  encrypted      = true

  tags = {
    Name = "efs"
  }
}

output "volume" {
  value = aws_efs_file_system.this[0].id
}