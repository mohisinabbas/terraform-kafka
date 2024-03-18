terraform {
  required_version = ">= 0.14.0"
  required_providers {
    confluent = {
      source  = "confluentinc/confluent"
      version = "1.61.0"
    }
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.17.0"
    }
  }
}

provider "confluent" {
  cloud_api_key    = var.confluent_cloud_api_key
  cloud_api_secret = var.confluent_cloud_api_secret
}

provider "aws" {
  region = "us-west-2"
  profile = "dev"
}

resource "confluent_environment" "staging" {
  display_name = "data-dev-env"
}

# Stream Governance and Kafka clusters can be in different regions as well as different cloud providers,
# but you should to place both in the same cloud and region to restrict the fault isolation boundary.
data "confluent_schema_registry_region" "advanced" {
  cloud   = "AWS"
  region  = "us-west-2"
  package = "ADVANCED"
}

resource "confluent_schema_registry_cluster" "advanced" {
  package = data.confluent_schema_registry_region.advanced.package
  environment {
    id = confluent_environment.staging.id
  }
  region {
    id = data.confluent_schema_registry_region.advanced.id
  }
}

resource "confluent_kafka_cluster" "dedicated" {
  display_name = "data-dev-dedicated"
  availability = "SINGLE_ZONE"
  cloud        = confluent_network.transit-gateway.cloud
  region       = confluent_network.transit-gateway.region
  dedicated {
    cku = 1
  }
  environment {
    id = confluent_environment.staging.id
  }
}

##### kafka rest proxy 1 #####

resource "confluent_service_account" "krp-sa-1" {
  display_name = "krp-sa-1"
  description  = "krp sa 1"
}

resource "confluent_role_binding" "krp-rb-1" {
  principal   = "User:${confluent_service_account.krp-sa-1.id}"
  role_name   = "DeveloperRead"
  crn_pattern = "${confluent_kafka_cluster.dedicated.rbac_crn}/kafka=${confluent_kafka_cluster.dedicated.id}/topic=*"
}

resource "confluent_api_key" "krp-api-key-1" {
  display_name = "krp-api-key-1"
  description  = "Kafka API Key owned by 'krp-sa-1' sa"

  # Set optional `disable_wait_for_ready` attribute (defaults to `false`) to `true` if the machine where Terraform is not run within a private network
  disable_wait_for_ready = true

  owner {
    id          = confluent_service_account.krp-sa-1.id
    api_version = confluent_service_account.krp-sa-1.api_version
    kind        = confluent_service_account.krp-sa-1.kind
  }

  managed_resource {
    id          = confluent_kafka_cluster.dedicated.id
    api_version = confluent_kafka_cluster.dedicated.api_version
    kind        = confluent_kafka_cluster.dedicated.kind

    environment {
      id = confluent_environment.staging.id
    }
  }

  depends_on = [confluent_role_binding.krp-rb-1]
}

##### kafka rest proxy 2 #####

resource "confluent_service_account" "krp-sa-2" {
  display_name = "krp-sa-2"
  description  = "krp sa 2"
}

resource "confluent_role_binding" "krp-rb-2" {
  principal   = "User:${confluent_service_account.krp-sa-2.id}"
  role_name   = "DeveloperRead"
  crn_pattern = "${confluent_kafka_cluster.dedicated.rbac_crn}/kafka=${confluent_kafka_cluster.dedicated.id}/topic=*"
}

resource "confluent_api_key" "krp-api-key-2" {
  display_name = "krp-api-key-2"
  description  = "Kafka API Key owned by 'krp-sa-2' sa"

  # Set optional `disable_wait_for_ready` attribute (defaults to `false`) to `true` if the machine where Terraform is not run within a private network
  disable_wait_for_ready = true

  owner {
    id          = confluent_service_account.krp-sa-2.id
    api_version = confluent_service_account.krp-sa-2.api_version
    kind        = confluent_service_account.krp-sa-2.kind
  }

  managed_resource {
    id          = confluent_kafka_cluster.dedicated.id
    api_version = confluent_kafka_cluster.dedicated.api_version
    kind        = confluent_kafka_cluster.dedicated.kind

    environment {
      id = confluent_environment.staging.id
    }
  }
  depends_on = [confluent_role_binding.krp-rb-2]
}

resource "aws_secretsmanager_secret" "restproxy_clients" {
  name = "cfk/secrets-dev/rest-basic.txt"
  description = "test tf secret"
}

resource "aws_secretsmanager_secret_version" "service_user" {
  secret_id     = aws_secretsmanager_secret.restproxy_clients.id
  secret_string = "${confluent_api_key.krp-api-key-1.id}: ${confluent_api_key.krp-api-key-1.secret},krp-users\n${confluent_api_key.krp-api-key-2.id}: ${confluent_api_key.krp-api-key-2.secret},krp-users\n"
}

resource "aws_secretsmanager_secret" "restproxy_jaas" {
  name = "cfk/secrets-dev/rest-ccloud-jaas-api-access.conf"
  description = "test tf jaas secret"
}

resource "aws_secretsmanager_secret_version" "rp_jaas_user" {
  secret_id     = aws_secretsmanager_secret.restproxy_jaas.id
  secret_string = "KafkaRest {\n org.eclipse.jetty.jaas.spi.PropertyFileLoginModule required \n debug=true \n file=/mnt/secrets/cp2ccloud-rest-users/basic.txt; \n};\n\nKafkaClient {\n org.apache.kafka.common.security.plain.PlainLoginModule required \n username=${confluent_api_key.krp-api-key-1.id} \n password=${confluent_api_key.krp-api-key-1.secret};\n\n org.apache.kafka.common.security.plain.PlainLoginModule required \n username=${confluent_api_key.krp-api-key-2.id} \n password=${confluent_api_key.krp-api-key-2.secret};\n};"
}
