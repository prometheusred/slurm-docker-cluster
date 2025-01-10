#!/bin/bash

set -e  # Exit on any command failure
set -u  # Treat unset variables as errors

# Check if a username was provided
if [ -z "$1" ]; then
    echo "Usage: $0 <username>"
    exit 1
fi

CLUSTER_NAME="linux"
ACCOUNT_NAME="root"
USER_NAME=$1
HOST_UID=$(id -u "$USER_NAME")
HOST_GID=$(id -g "$USER_NAME")

CONTAINER_NAME="slurmctld"
DATA_DIR=$(podman inspect "$CONTAINER_NAME" --format '{{ range .Mounts }}{{ if eq .Destination "/data" }}{{ .Destination }}{{ end }}{{ end }}')
DATA_RESULTS_DIR="$DATA_DIR/results"
DATA_VOLUME="slurm-docker-cluster_slurm_jobdir"
HOST_DATA_DIR=$(podman volume inspect "$DATA_VOLUME" --format "{{ .Mountpoint }}")
SLURM_GROUP="slurm"

# Print configuration values
echo "========== Configuration =========="
echo "Cluster Name      : $CLUSTER_NAME"
echo "Account Name      : $ACCOUNT_NAME"
echo "User Name         : $USER_NAME"
echo "Host UID          : $HOST_UID"
echo "Host GID          : $HOST_GID"
echo "Container Name    : $CONTAINER_NAME"
echo "Data Directory    : $DATA_DIR"
echo "Results Directory : $DATA_RESULTS_DIR"
echo "Data Volume       : $DATA_VOLUME"
echo "Host Data Directory: $HOST_DATA_DIR"
echo "Slurm Group       : $SLURM_GROUP"
echo "==================================="
echo

# Apply permissions on the host side
if [ -d "$HOST_DATA_DIR" ]; then
    echo "Setting permissions on host for $HOST_DATA_DIR..."
    sudo chown -R "$USER_NAME:$USER_NAME" "$HOST_DATA_DIR" || echo "Failed to change ownership of $HOST_DATA_DIR on the host"
    sudo chmod -R 775 "$HOST_DATA_DIR" || echo "Failed to set permissions for $HOST_DATA_DIR on the host"
else
    echo "Error: $HOST_DATA_DIR does not exist on the host."
    exit 1
fi

SERVICES=("slurmctld" "slurmdbd" "c1")

for SERVICE in "${SERVICES[@]}"; do
    echo "Adding user $USER_NAME with UID=$HOST_UID and GID=$HOST_GID to $SERVICE..."
    podman exec "$SERVICE" groupadd -g "$HOST_GID" "$USER_NAME" || echo "Group $USER_NAME already exists in $SERVICE"
    podman exec "$SERVICE" useradd -m -u "$HOST_UID" -g "$HOST_GID" "$USER_NAME" || echo "User $USER_NAME already exists in $SERVICE"
    
    echo "Adding user $USER_NAME to the $SLURM_GROUP group in $SERVICE..."
    podman exec "$SERVICE" usermod -aG "$SLURM_GROUP" "$USER_NAME" || echo "Failed to add user $USER_NAME to $SLURM_GROUP group in $SERVICE (may already be a member)"

    echo "Ensuring $DATA_DIR exists and is writable by $USER_NAME on $SERVICE..."
    podman exec "$SERVICE" mkdir -p "$DATA_DIR" || echo "Failed to create $DATA_DIR in $SERVICE (may already exist)"
    podman exec "$SERVICE" chown "$USER_NAME:$USER_NAME" "$DATA_DIR" || echo "Failed to change ownership of $DATA_DIR to $USER_NAME in $SERVICE"
    podman exec "$SERVICE" chmod 775 "$DATA_DIR" || echo "Failed to set permissions on $DATA_DIR in $SERVICE"

    echo "Ensuring $DATA_RESULTS_DIR exists and is writable by $USER_NAME on $SERVICE..."
    podman exec "$SERVICE" mkdir -p "$DATA_RESULTS_DIR"
    podman exec "$SERVICE" chown "$USER_NAME:$USER_NAME" "$DATA_RESULTS_DIR" || echo "Failed to change ownership of $DATA_DIR to $USER_NAME in $SERVICE"
    podman exec "$SERVICE" chmod 775 "$DATA_RESULTS_DIR" || echo "Failed to set permissions on $DATA_DIR in $SERVICE"
done

# Add user to Slurm accounting system
echo "Adding user $USER_NAME to the existing $ACCOUNT_NAME account in Slurm accounting system..."
podman exec slurmdbd sacctmgr -i add user name="$USER_NAME" account="$ACCOUNT_NAME" || echo "User $USER_NAME already exists in the Slurm accounting system"

# Verification
echo "Verifying user addition in the Slurm accounting system..."
podman exec slurmdbd sacctmgr -i show user format=User,DefaultAccount,Cluster


echo "Verifying container-side permissions for /data/results..."
podman exec "$CONTAINER_NAME" ls -ld "$DATA_RESULTS_DIR"

echo "User $USER_NAME added successfully to the Slurm cluster."
