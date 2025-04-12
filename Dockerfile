# Base image
FROM python:3.9-slim

# Install all system-level dependencies (including Chromium) before creating appuser
RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    wget \
    tar \
    xz-utils \
    fonts-liberation \
    fontconfig \
    build-essential \
    yasm \
    cmake \
    meson \
    ninja-build \
    nasm \
    libssl-dev \
    libvpx-dev \
    libx264-dev \
    libx265-dev \
    libnuma-dev \
    libmp3lame-dev \
    libopus-dev \
    libvorbis-dev \
    libtheora-dev \
    libspeex-dev \
    libfreetype6-dev \
    libfontconfig1-dev \
    libgnutls28-dev \
    libaom-dev \
    libdav1d-dev \
    librav1e-dev \
    libsvtav1-dev \
    libzimg-dev \
    libwebp-dev \
    git \
    pkg-config \
    autoconf \
    automake \
    libtool \
    libfribidi-dev \
    libharfbuzz-dev \
    chromium \
    chromium-driver \
    && rm -rf /var/lib/apt/lists/*

# Install SRT from source
RUN git clone https://github.com/Haivision/srt.git && \
    cd srt && mkdir build && cd build && cmake .. && \
    make -j$(nproc) && make install && cd ../.. && rm -rf srt

# Install SVT-AV1 from source
RUN git clone https://gitlab.com/AOMediaCodec/SVT-AV1.git && \
    cd SVT-AV1 && git checkout v0.9.0 && \
    cd Build && cmake .. && make -j$(nproc) && make install && cd ../.. && rm -rf SVT-AV1

# Install libvmaf from source
RUN git clone https://github.com/Netflix/vmaf.git && \
    cd vmaf/libvmaf && meson build --buildtype release && \
    ninja -C build && ninja -C build install && cd ../.. && rm -rf vmaf && ldconfig

# Build and install fdk-aac from source
RUN git clone https://github.com/mstorsjo/fdk-aac && \
    cd fdk-aac && autoreconf -fiv && ./configure && \
    make -j$(nproc) && make install && cd .. && rm -rf fdk-aac

# Build and install libunibreak from source
RUN git clone https://github.com/adah1972/libunibreak.git && \
    cd libunibreak && ./autogen.sh && ./configure && \
    make -j$(nproc) && make install && ldconfig && cd .. && rm -rf libunibreak

# Build and install libass with ASS_FEATURE_WRAP_UNICODE
RUN git clone https://github.com/libass/libass.git && \
    cd libass && autoreconf -i && ./configure --enable-libunibreak || { cat config.log; exit 1; } && \
    mkdir -p /app && cp config.log /app/config.log && \
    make -j$(nproc) || { echo "Libass build failed"; exit 1; } && \
    make install && ldconfig && cd .. && rm -rf libass

# Build and install FFmpeg
RUN git clone https://git.ffmpeg.org/ffmpeg.git ffmpeg && \
    cd ffmpeg && git checkout n7.0.2 && \
    PKG_CONFIG_PATH="/usr/lib/x86_64-linux-gnu/pkgconfig:/usr/local/lib/pkgconfig" \
    CFLAGS="-I/usr/include/freetype2" \
    LDFLAGS="-L/usr/lib/x86_64-linux-gnu" \
    ./configure --prefix=/usr/local \
        --enable-gpl \
        --enable-pthreads \
        --enable-neon \
        --enable-libaom \
        --enable-libdav1d \
        --enable-librav1e \
        --enable-libsvtav1 \
        --enable-libvmaf \
        --enable-libzimg \
        --enable-libx264 \
        --enable-libx265 \
        --enable-libvpx \
        --enable-libwebp \
        --enable-libmp3lame \
        --enable-libopus \
        --enable-libvorbis \
        --enable-libtheora \
        --enable-libspeex \
        --enable-libass \
        --enable-libfreetype \
        --enable-libharfbuzz \
        --enable-fontconfig \
        --enable-libsrt \
        --enable-filter=drawtext \
        --extra-cflags="-I/usr/include/freetype2 -I/usr/include/libpng16 -I/usr/include" \
        --extra-ldflags="-L/usr/lib/x86_64-linux-gnu -lfreetype -lfontconfig" \
        --enable-gnutls && \
    make -j$(nproc) && make install && cd .. && rm -rf ffmpeg

# Optional: include fonts (only if you have a fonts directory)
# COPY ./fonts /usr/share/fonts/custom
# RUN fc-cache -f -v

# Set environment paths
ENV PATH="/usr/local/bin:${PATH}"
ENV CHROME_BIN="/usr/bin/chromium"
ENV CHROMEDRIVER_BIN="/usr/bin/chromedriver"

# Set work directory
WORKDIR /app

# Whisper model cache
ENV WHISPER_CACHE_DIR="/app/whisper_cache"
RUN mkdir -p ${WHISPER_CACHE_DIR}

# Copy requirements and install Python dependencies
COPY requirements.txt .
RUN pip install --no-cache-dir --upgrade pip && \
    pip install --no-cache-dir -r requirements.txt && \
    pip install openai-whisper jsonschema

# Create non-root user AFTER all installs
RUN useradd -m appuser
RUN chown appuser:appuser /app

# Switch to non-root user
USER appuser

# Pre-load Whisper model (to avoid runtime load delay)
RUN python -c "import os; print(os.environ.get('WHISPER_CACHE_DIR')); import whisper; whisper.load_model('base')"

# Copy the rest of the application code
COPY . .

# Set environment variables
ENV PYTHONUNBUFFERED=1

# Expose port for the app
EXPOSE 8080

# Gunicorn run script
RUN echo '#!/bin/bash\n\
gunicorn --bind 0.0.0.0:8080 \
    --workers ${GUNICORN_WORKERS:-2} \
    --timeout ${GUNICORN_TIMEOUT:-300} \
    --worker-class sync \
    --keep-alive 80 \
    app:app' > /app/run_gunicorn.sh && \
    chmod +x /app/run_gunicorn.sh

# Start server
CMD ["/app/run_gunicorn.sh"]
