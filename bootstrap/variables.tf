variable "region" {
  description = "AWS region for state backend."
  type        = string
  default     = "ap-southeast-1"
}

variable "name_prefix" {
  description = "Short project prefix (matches NAME_PREFIX in .env)."
  type        = string
  default     = "cwta"
}

variable "owner" {
  description = "Owner tag value."
  type        = string
}

variable "tags" {
  description = "Common tags applied to bootstrap resources."
  type        = map(string)
  default     = {}
}
