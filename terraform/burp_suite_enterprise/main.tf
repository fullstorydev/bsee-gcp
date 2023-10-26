locals {
  services = toset([
    // burp enterprise requires persistent volume with ReadWriteMany access mode.
    // gke support this mode only when used with filestore
    "file.googleapis.com",
    // this api needs to be anabled to allow cloud sql auth proxy to work
    "sqladmin.googleapis.com",
  ])
  gke_namespace = "burp"
  postgress_users = toset([
    "burp_enterprise",
    "burp_agent",
  ])
  project_roles = toset([
    "cloudsql.client",
    "cloudsql.instanceUser",
  ])
  burp_cloud_sql_proxy_sa = "burp-suite-enterprise-cloud-sql-proxy"
}

resource "google_project_service" "services" {
  for_each = local.services
  project  = var.project
  service  = each.value

  disable_dependent_services = false
  disable_on_destroy         = false
}

resource "google_sql_database_instance" "burp" {
  name             = "burp"
  region           = var.region
  database_version = "POSTGRES_15"

  settings {
    # docs state that "db-g1-small" should be used for dev and testing only.
    # "db-custom-1-3840" is the smallest non prod tier
    tier = var.database_tier
    # WARN: disk_size should not be set when disk_autoresize is true
    # default disk_size is 10
    disk_autoresize = true     # this is default
    disk_type       = "PD_SSD" # this is default

    database_flags {
      name  = "cloudsql.iam_authentication"
      value = "on"
    }
  }
}

resource "google_sql_database" "burp_enterprise" {
  project  = var.project
  name     = "burp_enterprise"
  instance = google_sql_database_instance.burp.name
}

resource "random_password" "user_pwd" {
  for_each = local.postgress_users
  length   = 16
  special  = false
}

resource "google_sql_user" "user" {
  for_each = local.postgress_users
  project  = var.project
  name     = each.value
  instance = google_sql_database_instance.burp.name
  type     = "BUILT_IN"
  password = random_password.user_pwd[each.value].result
}

##
## This block is used for the cloud-sql-proxy portion of the burp deployment
## 
resource "google_service_account" "burp_cloud_sql_proxy" {
  account_id   = "burp-cloud-sql-proxy"
  display_name = "burp-cloud-sql-proxy"
}

resource "google_project_iam_member" "burp_cloud_sql_proxy_roles" {
  for_each = local.project_roles
  project  = var.project
  role     = "roles/${each.value}"
  member   = "serviceAccount:${google_service_account.burp_cloud_sql_proxy.email}"
}

// This enables linking the GCP service account to its Kubernetes equivalent
resource "google_service_account_iam_member" "burp_cloud_sql_proxy_binding" {
  service_account_id = google_service_account.burp_cloud_sql_proxy.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "serviceAccount:${var.project}.svc.id.goog[${local.gke_namespace}/${local.burp_cloud_sql_proxy_sa}]"
}
