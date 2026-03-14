FROM nvidia/cuda:12.2.0-devel-ubuntu22.04

ENV DEBIAN_FRONTEND=noninteractive
ENV TZ=Etc/UTC

# Enable multiarch for Steam/Proton 32-bit deps
RUN dpkg --add-architecture i386 && \
    apt-get update && \
    apt-get install -y software-properties-common && \
    rm -rf /var/lib/apt/lists/*

# Install ALL system dependencies
RUN apt-get update && apt-get install -y \
    wget curl gnupg sudo openssl xauth util-linux xvfb \
    xserver-xorg-core xserver-xorg-video-nvidia x11-xserver-utils xinit openbox \
    pulseaudio alsa-utils libasound2-plugins \
    libgl1 libgl1-mesa-glx libglu1-mesa libvulkan1 mesa-vulkan-drivers vulkan-tools \
    libgl1:i386 libgl1-mesa-glx:i386 libglu1-mesa:i386 libasound2:i386 \
    libxcursor1:i386 libxrandr2:i386 libxinerama1:i386 libxi6:i386 libxss1:i386 \
    libgtk-3-0:i386 libdbus-1-3:i386 libvulkan1:i386 \
    supervisor net-tools iproute2 \
    && rm -rf /var/lib/apt/lists/*

# Create gamer user with GPU group access
RUN useradd -m -s /bin/bash gamer && \
    echo "gamer:gamer" | chpasswd && \
    usermod -aG sudo,video,render gamer && \
    echo "gamer ALL=(ALL) NOPASSWD:ALL" >> /etc/sudoers

# Install Sunshine
RUN wget -q https://github.com/LizardByte/Sunshine/releases/latest/download/sunshine-ubuntu-22.04-amd64.deb && \
    apt-get update && \
    apt-get install -y -f ./sunshine-ubuntu-22.04-amd64.deb && \
    rm sunshine-ubuntu-22.04-amd64.deb && \
    rm -rf /var/lib/apt/lists/*

# Install Steam
RUN curl -sL -o /tmp/steam.deb https://cdn.cloudflare.steamstatic.com/client/installer/steam.deb && \
    dpkg -i /tmp/steam.deb || apt-get install -f -y && \
    rm /tmp/steam.deb && \
    rm -rf /var/lib/apt/lists/*

# Setup gamer home
USER gamer
WORKDIR /home/gamer
RUN mkdir -p .local/share/Steam && \
    rm -rf .steam && \
    ln -s .local/share/Steam .steam

USER root
COPY xorg.conf /etc/X11/xorg.conf
COPY supervisord.conf /etc/supervisord.conf
COPY start.sh /home/gamer/start.sh
COPY --chown=gamer:gamer healthcheck.sh /home/gamer/healthcheck.sh
COPY --chown=gamer:gamer autopair.sh /home/gamer/autopair.sh
RUN chown gamer:gamer /home/gamer/start.sh && \
    chmod +x /home/gamer/start.sh /home/gamer/healthcheck.sh /home/gamer/autopair.sh

ENV NVIDIA_VISIBLE_DEVICES=all
ENV NVIDIA_DRIVER_CAPABILITIES=all

EXPOSE 47984-48010/tcp
EXPOSE 47984-48010/udp
EXPOSE 47989/tcp

HEALTHCHECK --interval=30s --timeout=10s --start-period=15s --retries=3 \
    CMD /home/gamer/healthcheck.sh

CMD ["/home/gamer/start.sh"]
