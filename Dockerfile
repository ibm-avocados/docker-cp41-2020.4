from quay.io/clouddragons/openshift-cli-base:4.6


# Install apic cli
COPY apic-slim /usr/local/bin
RUN chmod +x /usr/local/bin/apic-slim

# Install apicops
RUN curl -LO  https://github.com/ibm-apiconnect/apicops/releases/download/v0.10.45/apicops-v10-linux
RUN  mv ./apicops-v10-linux  /usr/local/bin/apicops  && chmod +x /usr/local/bin/apicops

# Install go
#RUN curl -LO  https://golang.org/dl/go1.15.11.linux-amd64.tar.gz && tar -C /usr/local -zxf go1.15.11.linux-amd64.tar.gz
#ENV PATH /usr/local/go/bin:$PATH
RUN microdnf -y install go


# Install operator-sdk
RUN curl -LO https://github.com/operator-framework/operator-sdk/releases/latest/download/operator-sdk_linux_amd64
RUN  mv ./operator-sdk_linux_amd64  /usr/local/bin/operator-sdk  && chmod +x /usr/local/bin/operator-sdk


# Make expect script executable
RUN chmod +x /scripts/*.exp
