+++
date = '2025-02-23T12:00:00'
draft = false
title = 'Migrate Synapse Matrix Server for the Next-Gen Clients'
+++

I've been using Matrix for a few years,  but I always struggled to find a client that worked well —especially on my [degoogled](https://lineage.microg.org/) phone —  while also supporting the full range of Matrix features.

Recently, while browsing the web, I came across [SchildiChat](https://schildi.chat/), and more specifically [SchildiChat Next](https://schildi.chat/android/next/) — a client based on [Element X](https://element.io/app-for-productivity), which I had never heard of before. It seemed to be a complete rewrite of the old (and often buggy) Element client, so I was eager to give it a try.   

I installed the app, tried to connect to my server, and then…

![Screenshot_From_Element X.png](elementx-error.png)

## Where Things Started to Get Interesting

My server wasn't compatible :sob: .When I checked the ["*Learn more*"](https://github.com/matrix-org/sliding-sync/blob/main/docs/Landing.md) link in the GitHub documentation,the suggested solution seemed simple: "*update your Matrix server*".
**I was wrong.**
After scanning through the documentation, I noticed a small but crucial detail: I needed to install a "Sliding Sync proxy" —which wasn't as straightforward as I had hoped. 

At the time of writing, this whole setup is still relatively new, a bit experimental, and not yet designed to work seamlessly with Docker. Since my homelab is Docker-only and as declarative as possible, integrating everything took some effort. 

## Updating Synapse

This was the easiest part—I just had to update my Docker image to the latest version.
```diff
+++ docker-compose.matrix.yaml
 services:
   matrix-synapse:
-    image: matrixdotorg/synapse:v1.92.3
+    image: matrixdotorg/synapse:v1.123.0
```

## Installing the Sliding Sync Proxy

As there is an official Sliding Sync docker container, I just had to write a clean docker-compose for it.

```yaml
# docker-compose.matrix.yaml
services:
  matrix-sync:
    image: ghcr.io/matrix-org/sliding-sync:latest
    container_name: matrix-sync
    restart: unless-stopped
    depends_on:
      - postgres
      - matrix-synapse
    environment:
      - SYNCV3_SERVER=http://matrix-synapse:8008
      - SYNCV3_DB=postgres://postgres:${POSTGRES_PASSWORD}@postgres:5432/matrix_sync?sslmode=disable
      - SYNCV3_SECRET=${MATRIX_SYNC_SECRET}
      - SYNCV3_BINDADDR=:8009
    labels:
    - "traefik.enable=true"
    - "traefik.http.routers.matrix-sync.rule=Host(`syncv3.domain.tld`)"
    - "traefik.http.routers.matrix-sync.tls=true"
    - "traefik.http.routers.matrix-sync.tls.certresolver=http"
    - "traefik.http.routers.matrix-sync.entrypoints=internalsecure,externalsecure"
    - "traefik.http.services.matrix-sync.loadbalancer.server.port=8009"
    networks:
      - external
      - storage
      - matrix
```

### Notes on this setup: 
- **Separate Postgres Database**:  You'll need a new Postgres database, separate from your Synapse one. 
- **Secret Generation**:  The official documentation suggests generating a secret using:
```bash
echo -n "$(openssl rand -hex 32)"
```
- **Port Configuration**:  The service runs on `:8009` and needs to be accessible by clients — handled via Traefik in my case.
- **Synapse Networking**:  The proxy needs access to Synapse, so I added the `matrix` network and pointed it to `http://matrix-synapse:8008`.  
- **Version Pinning**: I used `latest` , but pinning a specific version is probably a good idea to avoid breaking changes.

## Configuring Synapse for Sliding Sync

### Updating the `.well-known` Configuration
This depends on your setup. In my case, I use **nginx**  to manage `.well-known` files. I had to update the config:  

```diff
+++ well-known/nginx.conf
http {
     location /.well-known/matrix/client {
       default_type application/json;
       add_header Access-Control-Allow-Origin *;
-      return 200 '{"m.homeserver":{"base_url":"https://matrix.domain.tld"}}';
+      return 200 '{"m.homeserver":{"base_url":"https://matrix.domain.tld"}, "org.matrix.msc3575.proxy": { "url": "https://syncv3.domain.tld" }}';
     }
}
```

### Enabling Sliding Sync in Synapse  
In `homeserver.yaml`, enable the experimental feature:   
```yaml
experimental_features:
  msc3575_enabled: true
```

At this point, if **you don't use an external identity provider**, congratulation :tada:, your setup *should* now work, and your server should works with the new clients! 

## Setting Up Matrix Authentication Service (MAS)

This is where things start to get really interesting — and where the declarative approach meets its limits.

### Deploying the MAS Container  

Thankfully, there’s a Docker image available for MAS, but unlike Synapse or Sliding Sync, it’s quite minimal and not designed to be run out of the box. We need to explicitly define the configuration in a YAML file, which includes both general settings and secrets. 

```yaml
# docker-compose.matrix.yaml
services:
  matrix-mas:
    image: ghcr.io/element-hq/matrix-authentication-service:latest
    container_name: matrix-mas
    restart: unless-stopped
    command: "server --config=/data/config.yaml"
    volumes:
      - ${DATA}/matrix/mas:/data:rw
    depends_on:
      - postgres
      - matrix-synapse
    labels:
    - "traefik.enable=true"
    - "traefik.http.routers.matrix-mas.rule=Host(`mas.domain.tld`)"
    - "traefik.http.routers.matrix-mas.tls=true"
    - "traefik.http.routers.matrix-mas.tls.certresolver=http"
    - "traefik.http.routers.matrix-mas.entrypoints=internalsecure,externalsecure"
    - "traefik.http.services.matrix-mas.loadbalancer.server.port=8080"
    networks:
      - external
      - storage
      - matrix
```

### Configuring MAS

The official documentation for the MAS configuration can be found [here](https://github.com/element-hq/matrix-authentication-service/blob/main/docs/reference/configuration.md).

Here are the key settings for our setup (**though you'll need additional configurations**, check the docs):

```yaml
#  matrix/mas/config.yaml

# Set up the public facing URL
http:
  public_base: https://mas.domain.tld
  
# Disable the password auth to use OIDC
passwords:
  enabled: false

# Allow MAS to manage your synapse server
matrix:
  homeserver: domain.tld
  secret: <VERY_SECURE_SECRET>
  endpoint: http://matrix-synpase:8008

# Allow synapse to manage MAS
clients:
  client_id: 0000000000000000000SYNAPSE  # Fixed length
  client_auth_method: client_secret_basic
  client_secret: <VERY_SECURE_SECRET>

# Configure your SSO provider (Authelia in my case)
upstream_oauth2:
  providers:
  ## Must be a valid ULID. The doc recommand to generate it on https://www.ulidtools.com/
  - id: THISISAVERYLONGVALIDULID00
    human_name: Authelia
	issuer: "https://idp.domain.tld" # Your OIDC provider URL
	client_id: "mas"
	client_secret: <VALID_OIDC_SECRE>
	token_endpoint_auth_method: client_secret_basic
    scope: "openid profile email"
    discovery_mode: insecure
    claims_imports:
        localpart:
          action: require
          template: "{{ user.preferred_username }}"
        displayname:
          action: suggest
          template: "{{ user.name }}"
        email:
          action: suggest
          template: "{{ user.email }}"
          set_email_verification: always
	
```

If you want to configure another SSO provider, check [the official doc](https://github.com/element-hq/matrix-authentication-service/blob/main/docs/setup/sso.md#sample-configurations). You will also need to configure the SSO provider itself, but that depends on your provider. 

### Configuring Synapse for MAS

In `homeserver.yaml`, we have to enable MAS support. You should ensure to use the same id and secrets as before.
```yaml
experimental_features:
  msc3575_enabled: true
  msc3861:
    enabled: true
    issuer: http://matrix-mas:8080/
    client_id: 0000000000000000000SYNAPSE
    client_auth_method: client_secret_basic
    client_secret: "<VERY_SECURE_SECRET>"
    admin_token: "<VERY_SECURE_SECRET>"
```

Also, ensure that `enable_registration` is set to `false`.

At this point, MAS should now be running :tada: ! You should be able to log in at `https://mas.domain.tld` using your SSO provider to verify the setup.

## Migrating Existing Users to MAS

The last (and most tricky) step is migrating existing Synapse users to MAS.   

Since I didn't want to install software I’d only use once, I opted again for Docker containers. But the commands can get a bit messy — so double-check them and ensure you understand what they do.

### Sync the database

Before migrating users, we need to sync the MAS config with the database. Remember I said it was a bit experimental?

If your MAS container is mounted the same way as mine, you can sync the config using:

```bash
docker exec -it matrix-mas mas-cli config sync --prune --config /data/config.yaml
```

### Preparing the migration

This is where things get complicated . The official migration container ([syn2mas](https://github.com/element-hq/matrix-authentication-service/pkgs/container/matrix-authentication-service%2Fsyn2mas)) requires access to
 - The Synapse configuration (`homeserver.yaml`)   
 - The MAS configuration (`config.yaml`)   
 - The databases they use (both SQLite and Postgres in my case)

And so, **the same way Synapse and MAS do**.

Since MAS uses postgres, the docker container must access the `storage` network, where my postgres container resides. However, since my Synapse instance uses SQLite, I also needed to mount the Synapse data folder.

If you're unsure about what you need to provide, just run it once — it will usually make you understand what is missing.

For convenience, I created an alias: 

```bash
alias syn2mas='docker run
  --rm
  --network storage
  -v ~/data/matrix/synapse/homeserver.yaml:/homeserver.yaml
  -v ~/data/matrix/synapse:/data
  -v ~/data/matrix/mas/config.yaml:/mas.yaml
  ghcr.io/element-hq/matrix-authentication-service/syn2mas'
```

### Checking the Migration Setup

Before migrating, you can verify that `syn2mas` can properly read the Synapse config:

```bash
syn2mas
	--command advisor
	--synapseConfigFile /homeserver.yaml
```

### Running the Migration (Dry Run & Final Execution)

Finally, we can run the migrate command. It will requires the configs as well as the OIDC id. We can first run a dry run to ensure that everything *should* works, then do the actual migration. For that, just remove the `--dryRun` option.

```bash
syn2mas
	--command migrate
	--synapseConfigFile /homeserver.yaml
	--masConfigFile /mas.yaml
	--upstreamProviderMapping oidc-authelia:<OAUTH_PROVIDER_ID>
	--dryRun true
```

At this point, I hit a final issue: the migration tool couldn’t access my MAS server. Removing `http.issuer` from the MAS config fixed it, even if I don't really know why. If you run into the same problem, you can try this fix!

## Limitations & Final Thoughts

Congratulations :tada:, you should now have a working Sliding Sync Server as well as a Matrix Authentication Server. I was way more efforts that I expected, but I'm happy I now have a future-proof matrix server (~~for how long?~~).

While the migration went smoothly, there are a few drawbacks.** Older Matrix clients can't connect  without additional configuration** (check the [documentation](https://element-hq.github.io/matrix-authentication-service)), and in my case, **images sent from new clients are not be visible on older servers**. Additionally, there’s no web client supporting the new setup yet, which might be inconvenient. 

## References
- [The official hosted documentation](https://element-hq.github.io/matrix-authentication-service)
- [The github documentation](https://github.com/element-hq/matrix-authentication-service/tree/main/docs)
