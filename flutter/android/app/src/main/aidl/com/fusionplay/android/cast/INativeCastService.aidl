package com.fusionplay.android.cast;

interface INativeCastService {
    void destroy() = 16777114;
    String setPaused(boolean paused, IBinder lifetime) = 1;
    String heartbeat() = 2;
    String getState() = 3;
}
