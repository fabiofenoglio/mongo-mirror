# syntax=docker/dockerfile:1

# Image for the MongoDB standby mirror, built to be deployed by Coolify and driven
# by a Scheduled Task.
#
# Why `mongo:8` rather than a slimmer base: it already ships mongodump, mongorestore
# and mongosh, and it is the image the script was tested in. For a job that runs once
# a day the image size hardly matters; being certain the tools behave as expected
# matters a great deal.
#
# Build context: the root of this repository.
# In Coolify: Build Context = "/", Dockerfile Location = "/Dockerfile".

FROM mongo:8

# The mongo image has an entrypoint that starts mongod. We do not want mongod here:
# this container is only the shell in which the Scheduled Task runs the script.
ENTRYPOINT []

COPY dr-mirror-mongo.sh /usr/local/bin/dr-mirror-mongo.sh
RUN chmod +x /usr/local/bin/dr-mirror-mongo.sh && mkdir -p /backup

# Where archives are written. Mount a persistent volume here, and include that volume
# in an offsite backup: an archive on the same disk you are protecting is not a safety
# copy.
ENV MONGO_MIRROR_WORKDIR=/backup
VOLUME ["/backup"]

# Coolify runs scheduled tasks inside an already-running container: if this exited
# immediately there would be nothing to step into. So it stays alive and inert.
CMD ["sleep", "infinity"]

# Deliberately shallow: it checks that the tools are present, not that the backup
# succeeded. Backup health lives in /backup/last-run.json and belongs to external
# monitoring — a container supervisor would react by restarting, which does not repair
# a failed backup.
HEALTHCHECK --interval=60s --timeout=10s --start-period=10s --retries=3 \
  CMD mongosh --version >/dev/null 2>&1 && mongodump --version >/dev/null 2>&1 || exit 1
