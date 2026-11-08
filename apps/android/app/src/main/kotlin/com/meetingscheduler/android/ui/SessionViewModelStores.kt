package com.meetingscheduler.android.ui

import androidx.compose.runtime.snapshotFlow
import androidx.lifecycle.ViewModel
import androidx.lifecycle.ViewModelProvider
import androidx.lifecycle.ViewModelStore
import androidx.lifecycle.ViewModelStoreOwner
import androidx.lifecycle.viewModelScope
import kotlinx.coroutines.launch

/**
 * The `ViewModelStore` for each signed-in session (F12, F13). It is itself an Activity-scoped
 * `ViewModel`, so it survives configuration changes, and it hands the authenticated screens a
 * store tied to the session's identity generation. When the generation changes (sign-out, a new
 * account, a new session for the same account) the older stores are cleared at once, which
 * cancels their screens' work and drops their state. A screen model therefore never outlives the
 * session that made it, and a recreated Activity gets back the models of the current session.
 *
 * [identityGeneration] is read in snapshot state, as the composition reads it.
 */
class SessionViewModelStores(private val identityGeneration: () -> Long) : ViewModel() {
    private class Owner : ViewModelStoreOwner {
        override val viewModelStore = ViewModelStore()
    }

    private val owners = mutableMapOf<Long, Owner>()

    init {
        viewModelScope.launch {
            snapshotFlow(identityGeneration).collect { retainOnly(it) }
        }
    }

    /** The store for [generation]; every other session's store is cleared first. */
    fun storeOwnerFor(generation: Long): ViewModelStoreOwner {
        retainOnly(generation)
        return owners.getOrPut(generation) { Owner() }
    }

    private fun retainOnly(generation: Long) {
        owners.keys.filter { it != generation }.forEach { owners.remove(it)?.viewModelStore?.clear() }
    }

    override fun onCleared() {
        owners.values.forEach { it.viewModelStore.clear() }
        owners.clear()
    }

    class Factory(private val identityGeneration: () -> Long) : ViewModelProvider.Factory {
        @Suppress("UNCHECKED_CAST")
        override fun <T : ViewModel> create(modelClass: Class<T>): T = SessionViewModelStores(identityGeneration) as T
    }
}
