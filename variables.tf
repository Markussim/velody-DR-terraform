variable "region" {
  description = "Region for deploy"

  default = "eu-north-1"
}

variable "secret_arn" {
  description = "ARN to the secret in your secrets manager"

  default = "arn:aws:secretsmanager:eu-north-1:637423239061:secret:velody-keys-M1U6RY"
}

