# Install AWS CLI

The AWS CLI will be used by terraform to perform it's operations from a local development environment.

- https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html

For local AWS development, I added a 1Password plugin that retrieves static creds and injects them on each call to `aws` by terraform (and you personal ad hoc CLI use)

- https://developer.1password.com/docs/cli/shell-plugins/aws/
