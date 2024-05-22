terraform {
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "4.67.0"
    }
  }
}

provider "google" {
  project = var.project_name
  region  = var.region
}

resource "google_compute_network" "vpc_network" {
  name                    = "my-custom-mode-network"
  auto_create_subnetworks = false
  mtu                     = 1460
}

resource "google_compute_network" "private_network" {
  name                    = "private-network"
  auto_create_subnetworks = false
  mtu                     = 1460
}

resource "google_compute_subnetwork" "default" {
  name          = "my-custom-subnet"
  ip_cidr_range = "10.0.1.0/24"
  region        = var.region
  network       = google_compute_network.vpc_network.id
}

resource "google_compute_subnetwork" "private" {
  name          = "private-subnet"
  ip_cidr_range = "10.0.2.0/24"
  region        = var.region
  network       = google_compute_network.private_network.id
}

resource "google_compute_instance" "default2" {
  name         = "flask-vm"
  machine_type = "f1-micro"
  zone         = var.zone
  tags         = ["ssh"]

  boot_disk {
    initialize_params {
      image = "debian-cloud/debian-11"
    }
  }

  # Install Flask
  metadata_startup_script = "sudo apt-get update; sudo apt-get install -yq build-essential python3-pip rsync; pip install flask"

  network_interface {
    subnetwork = google_compute_subnetwork.default.id
  }
}

resource "google_compute_instance" "default" {
  name         = "nginx-vm"
  machine_type = "f1-micro"
  zone         = var.zone
  tags         = ["ssh"]

  boot_disk {
    initialize_params {
      image = "debian-cloud/debian-11"
    }
  }

  # Install nginx
  metadata_startup_script = "sudo apt-get update; sudo apt-get install --assume-yes nginx"

  network_interface {
    subnetwork = google_compute_subnetwork.default.id

    access_config {
      # Include this section to give the VM an external IP address
    }
  }

  hostname = "app.georgij.com"
}

resource "google_compute_firewall" "ssh" {
  name = "allow-ssh"
  allow {
    ports    = ["22"]
    protocol = "tcp"
  }
  direction     = "INGRESS"
  network       = google_compute_network.vpc_network.id
  priority      = 1000
  source_ranges = ["0.0.0.0/0"]
  target_tags   = ["ssh"]
}

resource "google_compute_firewall" "ssh2" {
  name = "allow-ssh2"
  allow {
    ports    = ["22"]
    protocol = "tcp"
  }
  direction     = "INGRESS"
  network       = google_compute_network.private_network.id
  priority      = 1000
  source_ranges = ["0.0.0.0/0"]
  target_tags   = ["ssh"]
}

resource "google_compute_firewall" "flask" {
  name    = "flask-app-firewall"
  network = google_compute_network.vpc_network.id

  allow {
    protocol = "tcp"
    ports    = ["5000"]
  }
  source_ranges = ["0.0.0.0/0"]
}

resource "google_compute_firewall" "nginx" {
  name    = "nginx-server-firewall"
  network = google_compute_network.vpc_network.id

  allow {
    protocol = "tcp"
    ports    = ["80"]
  }
  source_ranges = ["0.0.0.0/0"]
}

resource "google_compute_firewall" "nginx-ssl" {
  name    = "nginx-server-firewall-ssl"
  network = google_compute_network.vpc_network.id

  allow {
    protocol = "tcp"
    ports    = ["443"]
  }
  source_ranges = ["0.0.0.0/0"]
}

resource "google_compute_global_address" "private_ip_address" {
  name          = "private-ip-address"
  purpose       = "VPC_PEERING"
  address_type  = "INTERNAL"
  prefix_length = 16
  network       = google_compute_network.private_network.id
}

resource "google_service_networking_connection" "private_vpc_connection" {
  network                 = google_compute_network.private_network.id
  service                 = "servicenetworking.googleapis.com"
  reserved_peering_ranges = [google_compute_global_address.private_ip_address.name]
}

resource "google_sql_database" "database" {
  name     = "my-database"
  instance = google_sql_database_instance.postgres.name
}

resource "google_sql_database_instance" "postgres" {
  name             = "postgres"
  database_version = "POSTGRES_15"
  region           = var.region

  depends_on = [google_service_networking_connection.private_vpc_connection]

  settings {
    # Second-generation instance tiers are based on the machine
    # type. See argument reference below.
    tier = "db-f1-micro"
    ip_configuration {
      ipv4_enabled                                  = false
      private_network                               = google_compute_network.private_network.id
      enable_private_path_for_google_cloud_services = true
    }
  }
}

resource "google_compute_instance" "bastion" {
  name         = "bastion-host"
  machine_type = "f1-micro"
  zone         = var.zone
  tags         = ["ssh"]

  boot_disk {
    initialize_params {
      image = "debian-cloud/debian-11"
    }
  }
  metadata_startup_script = "sudo apt-get update; sudo apt-get install --assume-yes postgresql-client; wget https://storage.googleapis.com/cloud-sql-connectors/cloud-sql-proxy/v2.8.2/cloud-sql-proxy.linux.amd64 -O cloud-sql-proxy; chmod +x cloud-sql-proxy"

  network_interface {
    network    = "private-network"
    subnetwork = google_compute_subnetwork.private.id
  }
}

resource "google_compute_network_peering" "peering1" {
  name         = "peering1"
  network      = google_compute_network.vpc_network.self_link
  peer_network = google_compute_network.private_network.self_link
}

resource "google_compute_network_peering" "peering2" {
  name         = "peering2"
  network      = google_compute_network.private_network.self_link
  peer_network = google_compute_network.vpc_network.self_link
}

resource "google_compute_firewall" "allow-tcp-rule" {
  project = var.project_name
  name    = "allow-tcp"
  network = google_compute_network.private_network.self_link

  allow {
    protocol = "tcp"
  }
  source_ranges = ["10.0.1.0/24"]
}

resource "google_compute_firewall" "allow-icmp-rule" {
  project = var.project_name
  name    = "allow-icmp"
  network = google_compute_network.vpc_network.self_link

  allow {
    protocol = "icmp"
  }
  source_ranges = ["10.0.2.0/24"]
}

resource "google_compute_firewall" "allow-tcp-from-private" {
  project = var.project_name
  name    = "allow-tcp2"
  network = google_compute_network.vpc_network.self_link

  allow {
    protocol = "tcp"
  }
  source_ranges = ["10.0.2.0/24"]
}

resource "google_compute_router" "router" {
  project = var.project_name
  name    = "nat-router"
  network = google_compute_network.private_network.self_link
  region  = var.region
}

module "cloud-nat" {
  source  = "terraform-google-modules/cloud-nat/google"
  version = "~> 5.0"

  project_id                         = var.project_name
  region                             = var.region
  router                             = google_compute_router.router.name
  name                               = "nat-config"
  source_subnetwork_ip_ranges_to_nat = "ALL_SUBNETWORKS_ALL_IP_RANGES"
}

resource "google_compute_router" "router2" {
  project = var.project_name
  name    = "nat-router2"
  network = google_compute_network.vpc_network.self_link
  region  = var.region
}

module "cloud-nat2" {
  source  = "terraform-google-modules/cloud-nat/google"
  version = "~> 5.0"

  project_id                         = var.project_name
  region                             = var.region
  router                             = google_compute_router.router2.name
  name                               = "nat-config"
  source_subnetwork_ip_ranges_to_nat = "ALL_SUBNETWORKS_ALL_IP_RANGES"
}