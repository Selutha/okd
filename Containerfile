FROM registry.access.redhat.com/ubi9:latest

RUN rpm -Uvh https://yum.puppet.com/puppet-tools-release-el-9.noarch.rpm \
 && dnf install -y pdk git \
 && dnf clean all

ENV PATH=/opt/puppetlabs/pdk/private/ruby/2.7.8/bin:/opt/puppetlabs/pdk/share/cache/ruby/2.7.0/bin:$PATH \
    GEM_HOME=/opt/puppetlabs/pdk/share/cache/ruby/2.7.0 \
    GEM_PATH=/opt/puppetlabs/pdk/share/cache/ruby/2.7.0:/opt/puppetlabs/pdk/private/puppet/ruby/2.7.0

WORKDIR /ufrc_rke2
ENTRYPOINT ["/bin/bash", "-c"]
CMD ["puppet-lint manifests/ && metadata-json-lint metadata.json && echo 'lint OK'"]
