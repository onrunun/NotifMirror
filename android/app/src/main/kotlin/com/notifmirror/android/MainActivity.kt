package com.notifmirror.android

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.BackHandler
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.compose.animation.AnimatedContent
import androidx.compose.animation.core.tween
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.slideInHorizontally
import androidx.compose.animation.slideOutHorizontally
import androidx.compose.animation.togetherWith
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import com.notifmirror.android.ui.FilterScreen
import com.notifmirror.android.ui.HomeScreen
import com.notifmirror.android.ui.PairingScreen
import com.notifmirror.android.ui.SettingsScreen
import com.notifmirror.android.ui.SetupScreen
import com.notifmirror.android.ui.areAnimationsEnabled
import com.notifmirror.android.ui.theme.NotifMirrorTheme

class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        setContent {
            NotifMirrorTheme {
                Surface(
                    modifier = Modifier.fillMaxSize(),
                    color = MaterialTheme.colorScheme.background
                ) {
                    Root()
                }
            }
        }
    }
}

@Composable
private fun Root() {
    val context = LocalContext.current
    val animationsEnabled = remember(context) { areAnimationsEnabled(context) }
    var backStack by rememberSaveable { mutableStateOf(listOf(Screen.Home.ordinal)) }

    BackHandler(enabled = backStack.size > 1) {
        backStack = backStack.dropLast(1)
    }

    val screen = Screen.entries[backStack.last()]

    AnimatedContent(
        targetState = screen,
        label = "screen",
        transitionSpec = {
            if (!animationsEnabled) {
                fadeIn(tween(0)).togetherWith(fadeOut(tween(0)))
            } else {
                val forward = targetState.ordinal > initialState.ordinal
                val dir = if (forward) 1 else -1
                (slideInHorizontally(tween(280)) { w -> dir * w / 6 } + fadeIn(tween(220)))
                    .togetherWith(
                        slideOutHorizontally(tween(280)) { w -> -dir * w / 6 } + fadeOut(tween(180))
                    )
            }
        }
    ) { current ->
        when (current) {
            Screen.Home -> HomeScreen(
                onPair = { backStack = backStack + Screen.Pairing.ordinal },
                onOpenFilter = { backStack = backStack + Screen.Filter.ordinal },
                onOpenSettings = { backStack = backStack + Screen.Settings.ordinal }
            )
            Screen.Settings -> SettingsScreen(
                onBack = { backStack = backStack.dropLast(1) },
                onPair = { backStack = backStack + Screen.Pairing.ordinal },
                onOpenFilter = { backStack = backStack + Screen.Filter.ordinal }
            )
            Screen.Pairing -> PairingScreen(
                // Replace Pairing with Setup so pressing Back returns cleanly to Home
                // instead of dropping back into the camera after pairing is saved.
                onDone = { backStack = backStack.dropLast(1) + Screen.Setup.ordinal },
                onCancel = { backStack = backStack.dropLast(1) }
            )
            Screen.Setup -> SetupScreen(
                onDone = { backStack = listOf(Screen.Home.ordinal) },
                onCancel = { backStack = backStack.dropLast(1) }
            )
            Screen.Filter -> FilterScreen(onBack = { backStack = backStack.dropLast(1) })
        }
    }
}

private enum class Screen { Home, Settings, Pairing, Setup, Filter }
