variable "region" {
  type    = string
  default = "eu-west-3"
}

variable "environment" {
  type    = string
  default = "dev"
}

variable "name" {
  description = "Préfixe des ressources."
  type        = string
  default     = "invoices"
}

variable "package_dir" {
  description = "Dossier contenant le code Lambda et ses dépendances (make build)."
  type        = string
  default     = "../build"
}

variable "approved_suppliers" {
  description = "Fournisseurs référencés (les autres exigent une validation humaine)."
  type        = list(string)
  default     = ["SBEE", "SONEB", "MTN Benin", "Moov Africa"]
}

variable "review_threshold" {
  description = "Montant TTC à partir duquel une facture exige une validation."
  type        = number
  default     = 5000000
}

variable "alert_email" {
  description = "E-mail des alertes (factures à vérifier, incidents). Vide = aucun abonnement."
  type        = string
  default     = ""
}

variable "log_retention_days" {
  type    = number
  default = 14
}

variable "lambda_timeout_seconds" {
  type    = number
  default = 30
}

variable "api_authorization" {
  description = <<-EOT
    Authentification de l'API :
      AWS_IAM : chaque requête doit être signée (SigV4) par une identité AWS
                autorisée — adapté à une API interne (défaut)
      NONE    : API publique, UNIQUEMENT pour une démonstration
    En production grand public : authentificateur JWT (Amazon Cognito).
  EOT
  type        = string
  default     = "AWS_IAM"
  validation {
    condition     = contains(["AWS_IAM", "NONE"], var.api_authorization)
    error_message = "api_authorization doit valoir AWS_IAM ou NONE."
  }
}
