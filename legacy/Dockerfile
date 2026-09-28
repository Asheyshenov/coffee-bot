# Coffee Bot Dockerfile
# Production-ready Ruby application container
# One image for all services: bin/migrate, bin/bot, bin/callback_app

FROM ruby:3.2-alpine

# Install system dependencies
RUN apk add --no-cache \
    build-base \
    postgresql-dev \
    postgresql-client \
    sqlite-dev \
    tzdata \
    bash

# Set working directory
WORKDIR /app

# Gems are installed into the image's GEM_HOME (/usr/local/bundle), outside /app,
# so `COPY . .` below can never overwrite them. The lockfile must match the
# Gemfile (frozen), dev/test gems are skipped.
ENV BUNDLE_FROZEN=true \
    BUNDLE_WITHOUT=development:test

# Copy Gemfile first for better caching
COPY Gemfile Gemfile.lock ./

# Install Ruby dependencies
RUN bundle install --jobs 4 --retry 3

# Copy application code (host vendor/, .bundle/, .env, sqlite DBs are excluded by .dockerignore)
COPY . .

# Safety net for .dockerignore: local databases (real client data) and secrets
# must never end up in the image
RUN found="$(find /app -name '*.sqlite*' -o -name '*.db' -o -name '*.db-*' \
                 -o -name '.env' -o -name '.env.*' ! -name '.env.example')"; \
    if [ -n "$found" ]; then \
      echo "Refusing to build: local database or .env in the image (check .dockerignore):" >&2; \
      echo "$found" >&2; \
      exit 1; \
    fi

# Create necessary directories
RUN mkdir -p /app/data/reports /app/db

# Make scripts executable
RUN chmod +x /app/bin/*

# Set environment
ENV RACK_ENV=production

# Default command (docker-compose overrides it per service)
CMD ["bin/bot"]
