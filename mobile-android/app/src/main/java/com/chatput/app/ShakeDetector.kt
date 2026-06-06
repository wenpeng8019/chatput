package com.chatput.app

import android.hardware.Sensor
import android.hardware.SensorEvent
import android.hardware.SensorEventListener
import android.hardware.SensorManager
import kotlin.math.sqrt

class ShakeDetector(private val onShake: () -> Unit) : SensorEventListener {
    private var lastX = 0f; private var lastY = 0f; private var lastZ = 0f
    private var lastTime = 0L
    private var shakeCount = 0
    private val threshold = 12f
    private val minInterval = 600L
    private val requiredShakes = 2

    override fun onSensorChanged(event: SensorEvent) {
        val now = System.currentTimeMillis()
        if (now - lastTime < 100) return
        val dx = event.values[0] - lastX
        val dy = event.values[1] - lastY
        val dz = event.values[2] - lastZ
        val accel = sqrt(dx * dx + dy * dy + dz * dz) / SensorManager.GRAVITY_EARTH
        if (accel > threshold) {
            if (now - lastTime > minInterval) shakeCount = 0
            shakeCount++
            if (shakeCount >= requiredShakes) { shakeCount = 0; onShake() }
        }
        lastTime = now; lastX = event.values[0]; lastY = event.values[1]; lastZ = event.values[2]
    }

    override fun onAccuracyChanged(sensor: Sensor?, accuracy: Int) {}
}
