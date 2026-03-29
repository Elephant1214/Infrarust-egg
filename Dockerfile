# First stage: prepare files with a regular Debian image
FROM debian:12-slim AS prepare

# Create container user required by Pterodactyl with specific UID/GID
RUN groupadd -g 999 container && \
    useradd -d /home/container -u 999 -g 999 -m container

# Create necessary directories
RUN mkdir -p /app/config && \
    chown -R container:container /app && \
    mkdir -p /home/container/servers && \
    chown -R container:container /home/container

# Copy the executable and set permissions
COPY infrarust /bin/infrarust
RUN chmod +x /bin/infrarust

COPY entrypoint.sh /bin/entrypoint.sh
RUN chmod +x /bin/entrypoint.sh

FROM debian:12-slim

# Copy user and group information
COPY --from=prepare /etc/passwd /etc/passwd
COPY --from=prepare /etc/group /etc/group

# Copy the executable
COPY --from=prepare /bin/infrarust /bin/infrarust
COPY --from=prepare /bin/entrypoint.sh /bin/entrypoint.sh

# Copy home directory structure
COPY --from=prepare --chown=container:container /home/container /home/container
COPY --from=prepare --chown=container:container /app /app

# Set the user to be used
USER container
ENV USER=container HOME=/home/container

# Setup work directory
WORKDIR /home/container

# Volume and port configuration
VOLUME ["/home/container"]
EXPOSE 25565

ENTRYPOINT ["/bin/bash", "/bin/entrypoint.sh"]
