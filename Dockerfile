# Coffee Bot Dockerfile
# Production-ready Ruby application container

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

# Copy Gemfile first for better caching
COPY Gemfile Gemfile.lock ./

# Install Ruby dependencies
RUN bundle config set --local deployment true && \
    bundle config set --local without development test && \
    bundle install --jobs 4 --retry 3

# Copy application code
COPY . .

# Create necessary directories
RUN mkdir -p /app/data/reports /app/db

# Make scripts executable
RUN chmod +x /app/bin/bot /app/bin/callback_app

# Set environment
ENV RACK_ENV=production

# Default command
CMD ["bin/bot"]
