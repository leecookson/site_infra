terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.32.0"
    }
  }
}

provider "azurerm" {
  # When doing a plan on CirleCI, it wants to change the "owner" to the 
  # service principal, and error indicates it needs subscription_id on the provider
  subscription_id = var.azure_subscription_id
  features {}
}
