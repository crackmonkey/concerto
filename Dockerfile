# Build the gem dependancies in a full image
FROM ruby:2.6-buster AS dependancies
ENV RAILS_ENV production
WORKDIR /usr/src/app
COPY Gemfile* ./
RUN bundle install --path vendor/bundle --with="postgres mysql"

# Install the app from a minimal base image
FROM ruby:2.6-slim-buster AS base

LABEL Author="team@concerto-signage.org"

# we need libreoffice to convert documents to pdfs, imagemagick for graphics handling
# Include all of the database libraries
RUN apt-get update
RUN DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends --no-upgrade libreoffice ghostscript imagemagick gsfonts poppler-utils git libpq5 libmariadb3 libsqlite3-0 nodejs

# set up for eastern timezone by default
RUN ln -fs /usr/share/zoneinfo/America/New_York /etc/localtime
RUN DEBIAN_FRONTEND=noninteractive apt-get install tzdata

# fix Imagemagick policy for converting files
# https://stackoverflow.com/a/52661288/1778068
RUN cat /etc/ImageMagick-6/policy.xml | sed 's/domain="coder" rights="none" pattern="PDF"/domain="coder" rights="read|write" pattern="PDF"/' >/etc/ImageMagick-6/policy.xml

# RAILS_ENV doesn't matter until we start doing actual ruby stuff
# So keep it after the base system package installation
ENV RAILS_ENV production

WORKDIR /usr/src/app
# Install dependancies from the build container
COPY --from=dependancies /usr/src/app/vendor/bundle/ vendor/bundle/
COPY --from=dependancies /usr/src/app/Gemfile.lock ./

# set up the concerto application
COPY Gemfile Gemfile.local Gemfile-plugins Gemfile-reporting ./
# Install the rest of the dependancies
RUN bundle install --deployment --path vendor/bundle --with="postgres mysql"

COPY . /usr/src/app
COPY config/database.yml.docker /usr/src/app/config/database.yml
RUN mkdir -p log tmp

# WARNING:
# automatic_bundle_installation=true in config/concerto.yml will
# remove the postgres pg gem if it detects mysql
# the bundle install --deployment above /might/ stop that
RUN bundle exec rake assets:precompile

RUN apt-get clean && rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*

# concerto will probably fail if any plugins are added/removed/changed because that is in the /home/app/concerto/Gemfile-plugin
# file which doesn't persist
VOLUME ["/usr/src/app/log", "/usr/src/app/tmp", "/usr/src/app/config"]

FROM base AS app
EXPOSE 3000
CMD ["/usr/src/app/bin/rails", "server", "-b", "0.0.0.0"]

FROM base AS worker
CMD ["/usr/src/app/bin/bundle", "exec", "rake", "jobs:work"]

FROM base AS clock
CMD ["/usr/src/app/bin/bundle", "exec", "clockwork", "lib/cron.rb"]

FROM nginx:stable-alpine AS staticcontent
COPY --from=base /usr/src/app/public/ /usr/share/nginx/html/

