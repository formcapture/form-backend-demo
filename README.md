# Form-Backend Demo Application

**Warning**: This is just a simple demo setup that is not suited for production use!

## Prerequisites for Development

1. Run `initDev.sh` to set all variables.
    * This script will prompt you for the local checkout of form-backend (formcapture)
    * Alternatively, you can pass the path as an argument: `./initDev.sh --form-backend-base=<<my-checkout>>/formcapture/form-backend`
    * If you want to re-initialize the setup, you have to clean up the setup before e.g., by running `docker compose down --remove-orphans ; sudo rm -rf postgres/data postgres-keycloak/data .env` to remove containers, existing databases and `.env` files.
1. Run `docker compose up -d` to start the setup.
    * During the first run, a ssl certificate for your local development is created and saved in `nginx/certs`.
1. Ensure sufficient permissions for `./form-backend/uploads/` (e.g. `chmod -R 777 form-backend/uploads`)

## Run Application

1. The application will be running on https://app.form-backend.local/form-backend/app/?formId=fountains_minimal&view=table`

The following applications are included:
- `/form-backend/app/?formId=fountains_minimal&view=table` - minimal configuration
- `/form-backend/app/?formId=fountains&view=table` - simple configuration of a single table with dropdown taken from a lookup table
- `/form-backend/app/?formId=fountains_advanced&view=table` - advanced kitchen sink configuration containing file uploads and join tables

### Add and Trust the Root Certificate of local dev setup
The `mkcert` container will automatically create a certificate along with a root certificate in the ./nginx/certs directory.
To ensure that your browser or other tools (like `curl`) can securely connect to your local form-backend-demo instance, you must first trust the root certificate.

For Debian/Ubuntu systems:

1. Copy the Root Certificate to the System's Trusted Store
```bash
sudo cp ./nginx/certs/rootCA.pem /usr/local/share/ca-certificates/rootCA.crt
```
2. Update the System's Trusted Certificates
```bash
sudo update-ca-certificates
```
3. Verify the Setup

Use curl to test the connection. If everything is set up correctly, there should be no SSL errors:

```bash
curl https://app.form-backend.local/form-backend/form/fountains_minimal
```

4. Removal of the Root Certificate (if not needed anymore)
```
sudo rm /usr/local/share/ca-certificates/rootCA.crt
sudo update-ca-certificates --fresh
```

5. Add the following line to your `/etc/hosts` file:
```
127.0.0.1  auth.form-backend.local
127.0.0.1  app.form-backend.local
```

## Integrate with Masterportal

A basic demo config is included to demonstrate the integration with a Masterportal instance: `https://localhost/portal/demo/`.

### Configuration

Please have a look at `masterportal/config/config.json` for an example. Docs can be found in the addon repository: https://github.com/formcapture/masterportal-addons/tree/main/addons/embedit
