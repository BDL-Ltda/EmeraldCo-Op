FROM devkitpro/devkitarm:20260610@sha256:15b79ce75822c289538d8153da5fa7aafe5e6adc32ad8a575a197beca0f0761b

# The base already provides GCC/G++, make, Perl, pkg-config and rsync.
# Freeze the extra host dependency to the same Debian snapshot on every machine.
COPY debian.sources /etc/apt/rom-build.sources
RUN apt-get -o Dir::Etc::sourcelist=rom-build.sources -o Dir::Etc::sourceparts=- update \
    && apt-get -o Dir::Etc::sourcelist=rom-build.sources -o Dir::Etc::sourceparts=- \
        install -y --no-install-recommends libpng-dev \
    && rm -rf /var/lib/apt/lists/*

ENV PATH="/opt/devkitpro/devkitARM/bin:${PATH}" \
    LC_ALL=C.UTF-8 \
    TZ=UTC \
    SOURCE_DATE_EPOCH=0

COPY --chmod=755 build-rom.sh /usr/local/bin/build-rom
WORKDIR /build/rom
ENTRYPOINT ["/usr/local/bin/build-rom"]
