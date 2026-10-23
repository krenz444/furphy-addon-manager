<script lang="ts">
  import { invoke, isMockMode } from './lib/ipc';
  import Sidebar from './components/layout/Sidebar.svelte';
  import MyAddonsView from './views/MyAddonsView.svelte';
  import GetAddonsView from './views/GetAddonsView.svelte';
  import NotBuiltForPatchView from './views/NotBuiltForPatchView.svelte';
  import SettingsView from './views/SettingsView.svelte';
  import AddonDrawer from './components/drawer/AddonDrawer.svelte';
  import AddAddonDialog from './components/dialogs/AddAddonDialog.svelte';
  import ExportDialog from './components/dialogs/ExportDialog.svelte';
  import ProtocolConsentDialog from './components/dialogs/ProtocolConsentDialog.svelte';
  import ConfirmDialog from './components/dialogs/ConfirmDialog.svelte';
  import JobPanel from './components/jobs/JobPanel.svelte';
  import Toasts, { type ToastItem } from './components/jobs/Toasts.svelte';
  import AppUpdateBanner from './components/banners/AppUpdateBanner.svelte';
  import type { Addon, Flavour, AppInfo, Freshness, JobRecord, PatchCompatStatus, AppUpdateInfo } from './lib/types';

  // Navigation State
  let activeView = $state<'my_addons' | 'get_addons' | 'not_built_for_patch' | 'settings'>('my_addons');

  // Application Data
  let appInfo = $state<AppInfo | null>(null);
  let flavours = $state<Flavour[]>([]);
  let activeFlavour = $state<string>('retail');
  let addons = $state<Addon[]>([]);
  let freshness = $state<Freshness | null>(null);
  let compatList = $state<PatchCompatStatus[]>([]);
  let untrackedCount = $state<number>(0);
  let isGameActive = $state<boolean>(false);
  let appUpdate = $state<AppUpdateInfo | null>(null);
  let updateBannerDismissed = $state<boolean>(false);
  let isInstallingAppUpdate = $state<boolean>(false);

  // Preference State
  let currentTheme = $state<string>('tokyo-rain');
  let density = $state<'comfortable' | 'compact'>('comfortable');

  // Running Job & Toasts
  let runningJob = $state<JobRecord | null>(null);
  let activeJobPhase = $state<string>('Checking');
  let currentJobAddon = $state<string>('');
  let jobIndex = $state<number>(0);
  let jobTotal = $state<number>(0);
  let jobLogs = $state<string[]>([]);
  let reloadNeeded = $state<boolean>(false);
  let toasts = $state<ToastItem[]>([]);

  // Overlays & Dialogs State
  let activeDrawerAddon = $state<Addon | null>(null);
  let activeDrawerTab = $state<string>('overview');
  let addDialogOpen = $state<boolean>(false);
  let exportDialogOpen = $state<boolean>(false);

  // Confirm Dialog State
  let confirmOpen = $state<boolean>(false);
  let confirmTitle = $state<string>('Are you sure?');
  let confirmMessage = $state<string>('');
  let confirmDetail = $state<string | null>(null);
  let confirmDanger = $state<boolean>(false);
  let confirmAction = $state<(() => void) | null>(null);

  // Protocol Consent Dialog State
  let protocolOpen = $state<boolean>(false);
  let protocolUrl = $state<string>('');
  let protocolAddonId = $state<number>(0);
  let protocolFileId = $state<number | null>(null);
  let protocolAddonName = $state<string | null>(null);

  let isWindowFocused = $state<boolean>(true);
  let showTestRealms = $state<boolean>(false);

  // Computed Tallies
  let updatesCount = $derived(freshness?.updates_count ?? addons.filter(a => !!a.update_version).length);
  let notBuiltCount = $derived(compatList.length > 0 ? compatList.length : addons.filter(a => a.is_old_patch).length);

  // Listen to Window Focus/Blur for Animation Pausing (§2.F, §4.7)
  $effect(() => {
    const onFocus = () => { isWindowFocused = true; };
    const onBlur = () => { isWindowFocused = false; };
    const onVis = () => { isWindowFocused = !document.hidden; };

    window.addEventListener('focus', onFocus);
    window.addEventListener('blur', onBlur);
    document.addEventListener('visibilitychange', onVis);

    return () => {
      window.removeEventListener('focus', onFocus);
      window.removeEventListener('blur', onBlur);
      document.removeEventListener('visibilitychange', onVis);
    };
  });

  // Apply Theme & Density & Pause Attributes to DOM
  $effect(() => {
    document.documentElement.dataset.theme = currentTheme;
    document.documentElement.dataset.density = density;
    document.documentElement.dataset.gameActive = String(isGameActive);
    document.documentElement.dataset.windowInactive = String(!isWindowFocused);
  });

  function addToast(type: 'info' | 'success' | 'warning' | 'error', message: string, durationMs = 4000) {
    const id = 'toast-' + Math.random().toString(36).substring(2, 9);
    toasts = [...toasts, { id, type, message }];
    setTimeout(() => {
      toasts = toasts.filter(t => t.id !== id);
    }, durationMs);
  }

  async function loadInitialData() {
    try {
      try {
        appInfo = await invoke<AppInfo>('get_app_info');
      } catch {
        appInfo = {
          name: 'Furphy Dev',
          version: '2.0.0-dev',
          is_dev: true,
          identifier: 'krenzcreative.furphy.addonmanager.dev',
        };
      }

      try {
        const s = await invoke<Record<string, any>>('get_settings');
        if (s) {
          if (s.showTestRealms !== undefined) showTestRealms = Boolean(s.showTestRealms);
          if (s.hostTheme) currentTheme = s.hostTheme;
        }
      } catch {}

      try {
        const fl = await invoke<Flavour[]>('get_flavours');
        flavours = fl && fl.length > 0 ? fl : [{ id: 'retail', folder: '_retail_', label: 'Retail', product: null, installed: true }];
        if (!flavours.some(f => f.id === activeFlavour)) {
          activeFlavour = flavours[0].id;
        }
      } catch {
        flavours = [{ id: 'retail', folder: '_retail_', label: 'Retail', product: null, installed: true }];
      }

      try {
        const u = await invoke<AppUpdateInfo>('app_update_status');
        if (u && u.has_update && u.update_version) {
          appUpdate = u;
        }
      } catch {}

      await refreshFlavourData(activeFlavour);
    } catch (err) {
      console.error('Failed to load initial data:', err);
    }
  }

  async function refreshFlavourData(flavourId: string) {
    try {
      const stateRes = await invoke<{
        addons?: Addon[];
        freshness?: Freshness;
        running_job?: JobRecord | null;
        untracked_count?: number;
        is_game_active?: boolean;
      }>('get_state', { flavour: flavourId });

      if (stateRes) {
        if (stateRes.addons) addons = stateRes.addons;
        if (stateRes.freshness) freshness = stateRes.freshness;
        if (stateRes.running_job !== undefined) runningJob = stateRes.running_job;
        if (stateRes.untracked_count !== undefined) untrackedCount = stateRes.untracked_count;
        if (stateRes.is_game_active !== undefined) isGameActive = stateRes.is_game_active;
      }

      try {
        compatList = await invoke<PatchCompatStatus[]>('list_not_built_for_patch', { flavour: flavourId });
      } catch {
        compatList = [];
      }
    } catch (err) {
      console.warn('Could not refresh flavour data:', err);
      try {
        addons = await invoke<Addon[]>('get_addons', { flavour: flavourId });
      } catch {
        addons = [];
      }
    }
  }

  function handleFlavourChange(flavourId: string) {
    activeFlavour = flavourId;
    refreshFlavourData(flavourId);
  }

  function handleThemeChange(theme: string) {
    currentTheme = theme;
    invoke('set_window_theme', { theme }).catch(() => {});
  }

  function handleDensityChange(newDensity: 'comfortable' | 'compact') {
    density = newDensity;
  }

  // Job Triggers
  async function handleCheckNow() {
    try {
      runningJob = {
        id: 'job-check-' + Date.now(),
        kind: 'check',
        flavour: activeFlavour,
        params: null,
        state: 'running',
        started_at: new Date().toISOString(),
        finished_at: null,
        error: null,
        results: null,
        reload_needed: false,
        log_path: null,
      };
      activeJobPhase = 'Checking';
      currentJobAddon = 'Contacting repositories…';
      jobLogs = ['[Check] Starting check for ' + activeFlavour];

      await invoke('start_job', { kind: 'check', flavour: activeFlavour });
      addToast('info', 'Check complete.');
      await refreshFlavourData(activeFlavour);
      runningJob = null;
    } catch (err: unknown) {
      if (runningJob) {
        runningJob = { ...runningJob, state: 'failed', error: String(err) };
      }
      addToast('error', 'Check failed: ' + err);
    }
  }

  async function handleUpdateAll() {
    try {
      runningJob = {
        id: 'job-sync-' + Date.now(),
        kind: 'sync',
        flavour: activeFlavour,
        params: null,
        state: 'running',
        started_at: new Date().toISOString(),
        finished_at: null,
        error: null,
        results: null,
        reload_needed: isGameActive,
        log_path: null,
      };
      activeJobPhase = 'Updating';
      currentJobAddon = 'Downloading updates…';
      jobLogs = ['[Sync] Updating all eligible addons for ' + activeFlavour];

      await invoke('start_job', { kind: 'sync', flavour: activeFlavour });
      addToast('success', 'All addons updated successfully.');
      if (isGameActive) {
        reloadNeeded = true;
      }
      await refreshFlavourData(activeFlavour);
      runningJob = null;
    } catch (err: unknown) {
      if (runningJob) {
        runningJob = { ...runningJob, state: 'failed', error: String(err) };
      }
      addToast('error', 'Update failed: ' + err);
    }
  }

  async function handleUpdateAddon(addon: Addon) {
    try {
      await invoke('start_job', { kind: 'sync', flavour: activeFlavour, params: { addon_ids: [addon.id] } });
      addToast('success', `Updated ${addon.name ?? addon.id}`);
      if (isGameActive) {
        reloadNeeded = true;
      }
      await refreshFlavourData(activeFlavour);
    } catch (err) {
      addToast('error', `Failed to update ${addon.name ?? addon.id}: ${err}`);
    }
  }

  async function handleUpdateSelected(selected: Addon[]) {
    if (selected.length === 0) return;
    try {
      const ids = selected.map(a => a.id);
      await invoke('start_job', { kind: 'sync', flavour: activeFlavour, params: { addon_ids: ids } });
      addToast('success', `Updated ${selected.length} addons`);
      if (isGameActive) {
        reloadNeeded = true;
      }
      await refreshFlavourData(activeFlavour);
    } catch (err) {
      addToast('error', `Bulk update failed: ${err}`);
    }
  }

  function handleUninstallAddon(addon: Addon) {
    confirmTitle = 'Uninstall Addon';
    confirmMessage = `Are you sure you want to uninstall "${addon.name ?? addon.id}"?`;
    confirmDetail = `This will remove the package folders from your Interface\\AddOns directory:\n${addon.folders.join('\n')}\nYour SavedVariables settings will be preserved.`;
    confirmDanger = true;
    confirmAction = async () => {
      try {
        await invoke('start_job', { kind: 'remove', flavour: activeFlavour, params: { addon_id: addon.id } });
        addToast('info', `Uninstalled ${addon.name ?? addon.id}`);
        await refreshFlavourData(activeFlavour);
      } catch (err) {
        addToast('error', `Uninstall failed: ${err}`);
      }
      confirmOpen = false;
    };
    confirmOpen = true;
  }

  function handleUninstallSelected(selected: Addon[]) {
    if (selected.length === 0) return;
    confirmTitle = 'Uninstall Selected Addons';
    confirmMessage = `Are you sure you want to uninstall ${selected.length} selected addons?`;
    confirmDetail = `This will remove the associated folders for:\n${selected.map(a => a.name ?? a.id).join(', ')}`;
    confirmDanger = true;
    confirmAction = async () => {
      try {
        for (const addon of selected) {
          await invoke('start_job', { kind: 'remove', flavour: activeFlavour, params: { addon_id: addon.id } });
        }
        addToast('info', `Uninstalled ${selected.length} addons`);
        await refreshFlavourData(activeFlavour);
      } catch (err) {
        addToast('error', `Bulk uninstall failed: ${err}`);
      }
      confirmOpen = false;
    };
    confirmOpen = true;
  }

  async function handleTogglePin(addon: Addon) {
    try {
      if (addon.pinned_file_id) {
        await invoke('unpin', { id: addon.id });
        addToast('info', `Unpinned ${addon.name ?? addon.id}`);
      } else if (addon.file_id) {
        await invoke('pin_version', { id: addon.id, file_id: addon.file_id });
        addToast('info', `Pinned ${addon.name ?? addon.id} to current version`);
      }
      await refreshFlavourData(activeFlavour);
    } catch (err) {
      addToast('error', `Failed toggling pin: ${err}`);
    }
  }

  async function handleToggleIgnore(addon: Addon) {
    try {
      const nextIgnore = !addon.ignore_updates;
      await invoke('set_ignore', { id: addon.id, ignore: nextIgnore });
      addToast('info', nextIgnore ? `Ignored updates for ${addon.name ?? addon.id}` : `Resumed updates for ${addon.name ?? addon.id}`);
      await refreshFlavourData(activeFlavour);
    } catch (err) {
      addToast('error', `Failed toggling ignore: ${err}`);
    }
  }

  function handleOpenSource(addon: Addon) {
    let url = '';
    if (addon.source === 'curseforge' && addon.project_id) {
      url = `https://www.curseforge.com/wow/addons/${addon.project_id}`;
    } else if (addon.source === 'wago' && addon.wago_slug) {
      url = `https://addons.wago.io/addons/${addon.wago_slug}`;
    } else if (addon.source === 'github' && addon.repo) {
      url = `https://github.com/${addon.repo}`;
    }
    if (url) {
      invoke('open_target', { what: 'url', args: [url] }).catch(() => {});
    }
  }

  async function handleAddAddon(target: string) {
    await invoke('start_job', { kind: 'add', flavour: activeFlavour, params: { target } });
    addToast('success', 'Addon installed successfully');
    if (isGameActive) {
      reloadNeeded = true;
    }
    await refreshFlavourData(activeFlavour);
  }

  async function handleExportAddonList(includeWtf: boolean): Promise<string> {
    const res = await invoke<string | { path: string }>('export_list', { flavour: activeFlavour, include_wtf: includeWtf });
    addToast('success', 'Addon list exported.');
    if (typeof res === 'string') return res;
    return (res as any)?.path || 'Exported successfully';
  }

  async function handleImportAddonList() {
    try {
      const count = await invoke<number>('import_list', { flavour: activeFlavour, path: null });
      addToast('success', `Imported ${count} addon(s) successfully.`);
      await refreshFlavourData(activeFlavour);
    } catch (err) {
      addToast('error', `Import failed: ${err}`);
    }
  }

  async function handleRollbackAddon(addon: Addon) {
    confirmTitle = `Roll back ${addon.name ?? addon.id}?`;
    confirmMessage = `Are you sure you want to restore the previous backup of this addon?`;
    confirmDetail = `Previous version backup will be restored. Your SavedVariables settings are preserved.`;
    confirmDanger = false;
    confirmAction = async () => {
      try {
        await invoke('start_job', { kind: 'rollback', flavour: activeFlavour, params: { addon_id: addon.id } });
        addToast('success', `Rolled back ${addon.name ?? addon.id}`);
        await refreshFlavourData(activeFlavour);
      } catch (err) {
        addToast('error', `Rollback failed: ${err}`);
      }
      confirmOpen = false;
    };
    confirmOpen = true;
  }

  async function handleManageAllUntracked() {
    try {
      await invoke('adopt_all_untracked', { flavour: activeFlavour });
      addToast('success', 'Managed all untracked addons.');
      await refreshFlavourData(activeFlavour);
    } catch (err) {
      addToast('error', `Failed managing untracked addons: ${err}`);
    }
  }

  function handleOpenAddonDrawer(addon: Addon, tab = 'overview') {
    activeDrawerAddon = addon;
    activeDrawerTab = tab;
  }

  function handleProtocolConsent(flavour: string, addonId: number, fileId?: number | null) {
    protocolOpen = false;
    invoke('start_job', {
      kind: 'install',
      flavour,
      params: { project_id: addonId, file_id: fileId },
    }).then(() => {
      addToast('success', `Installed addon #${addonId}`);
      if (isGameActive) {
        reloadNeeded = true;
      }
      refreshFlavourData(activeFlavour);
    }).catch(err => {
      addToast('error', `Protocol install failed: ${err}`);
    });
  }

  loadInitialData();
</script>

<div class="app-layout">
  <Sidebar
    {activeView}
    {activeFlavour}
    {flavours}
    {freshness}
    {updatesCount}
    {notBuiltCount}
    {isGameActive}
    {appInfo}
    {showTestRealms}
    onSelectView={(v) => (activeView = v)}
    onSelectFlavour={handleFlavourChange}
    onCheckNow={handleCheckNow}
    onUpdateAll={handleUpdateAll}
  />

  <main class="main-viewport">
    {#if runningJob}
      <JobPanel
        job={runningJob}
        activePhase={activeJobPhase}
        currentAddon={currentJobAddon}
        progressIndex={jobIndex}
        progressTotal={jobTotal}
        logs={jobLogs}
        onRetry={handleCheckNow}
        onDismiss={() => (runningJob = null)}
        onOpenLog={() => invoke('open_target', { what: 'lastrun', args: [] })}
      />
    {/if}

    {#if appUpdate && appUpdate.has_update && appUpdate.update_version && !updateBannerDismissed}
      <AppUpdateBanner
        updateVersion={appUpdate.update_version}
        releaseNotes={appUpdate.release_notes}
        isInstalling={isInstallingAppUpdate}
        onInstall={async () => {
          isInstallingAppUpdate = true;
          try {
            await invoke('app_update_install');
            addToast('info', 'Installing update and relaunching...');
          } catch (err: any) {
            isInstallingAppUpdate = false;
            addToast('error', `Update installation failed: ${err}`);
          }
        }}
        onDismiss={() => (updateBannerDismissed = true)}
      />
    {/if}

    <div class="view-container">
      {#if activeView === 'my_addons'}
        <MyAddonsView
          {addons}
          flavour={activeFlavour}
          {density}
          {untrackedCount}
          onUpdateAddon={handleUpdateAddon}
          onUpdateAll={handleUpdateAll}
          onUpdateSelected={handleUpdateSelected}
          onUninstallAddon={handleUninstallAddon}
          onUninstallSelected={handleUninstallSelected}
          onTogglePin={handleTogglePin}
          onToggleIgnore={handleToggleIgnore}
          onRollbackAddon={handleRollbackAddon}
          onOpenAddonDrawer={handleOpenAddonDrawer}
          onOpenAddDialog={() => (addDialogOpen = true)}
          onOpenSource={handleOpenSource}
          onManageAllUntracked={handleManageAllUntracked}
          onViewUntracked={() => (activeView = 'settings')}
          onDensityChange={handleDensityChange}
        />
      {:else if activeView === 'get_addons'}
        <GetAddonsView
          flavour={activeFlavour}
          onInstallWago={(slug) => handleAddAddon(`https://addons.wago.io/addons/${slug}`)}
          onInstallCurseForge={(projectId) => handleAddAddon(String(projectId))}
          onInstallGitHub={(repoUrl) => handleAddAddon(repoUrl)}
        />
      {:else if activeView === 'not_built_for_patch'}
        <NotBuiltForPatchView
          flavour={activeFlavour}
          {addons}
          {compatList}
          onCheckNow={async (addonId) => {
            await invoke('start_job', { kind: 'check', flavour: activeFlavour, params: { addon_ids: [addonId] } });
            await refreshFlavourData(activeFlavour);
          }}
          onUpdate={handleUpdateAddon}
          onPin={handleTogglePin}
          onOpenWeb={handleOpenSource}
        />
      {:else if activeView === 'settings'}
        <SettingsView
          flavour={activeFlavour}
          {currentTheme}
          {density}
          onThemeChange={handleThemeChange}
          onDensityChange={handleDensityChange}
          onExportList={() => (exportDialogOpen = true)}
          onImportList={handleImportAddonList}
          onRequestUninstall={() => {
            confirmTitle = 'Uninstall Furphy Addon Manager';
            confirmMessage = 'Are you sure you want to uninstall Furphy Addon Manager?';
            confirmDetail = 'Your World of Warcraft addons and SavedVariables settings will remain untouched.';
            confirmDanger = true;
            confirmAction = () => {
              invoke('uninstall_app').catch(() => {});
              confirmOpen = false;
            };
            confirmOpen = true;
          }}
        />
      {/if}
    </div>
  </main>

  <!-- Right Addon Drawer -->
  {#if activeDrawerAddon}
    <AddonDrawer
      addon={activeDrawerAddon}
      initialTab={activeDrawerTab}
      {isGameActive}
      onClose={() => (activeDrawerAddon = null)}
      onInstallVersion={async (addon, fileId) => {
        await invoke('start_job', { kind: 'install', flavour: activeFlavour, params: { project_id: addon.project_id, file_id: fileId } });
        addToast('success', `Installed version ${fileId}`);
        await refreshFlavourData(activeFlavour);
      }}
      onPinVersion={async (addon, fileId) => {
        await invoke('pin_version', { id: addon.id, file_id: fileId });
        addToast('info', `Pinned to version ${fileId}`);
        await refreshFlavourData(activeFlavour);
      }}
    />
  {/if}

  <!-- Overlays & Modals -->
  <AddAddonDialog
    isOpen={addDialogOpen}
    onClose={() => (addDialogOpen = false)}
    onAdd={handleAddAddon}
  />

  <ExportDialog
    isOpen={exportDialogOpen}
    flavour={activeFlavour}
    onClose={() => (exportDialogOpen = false)}
    onExport={handleExportAddonList}
  />

  <ProtocolConsentDialog
    open={protocolOpen}
    url={protocolUrl}
    addonId={protocolAddonId}
    fileId={protocolFileId}
    addonName={protocolAddonName}
    {flavours}
    selectedFlavour={activeFlavour}
    onConfirm={handleProtocolConsent}
    onCancel={() => (protocolOpen = false)}
  />

  <ConfirmDialog
    open={confirmOpen}
    title={confirmTitle}
    message={confirmMessage}
    detail={confirmDetail}
    isDanger={confirmDanger}
    onConfirm={() => confirmAction?.()}
    onCancel={() => (confirmOpen = false)}
  />

  <Toasts
    {reloadNeeded}
    {toasts}
    onDismissReload={() => (reloadNeeded = false)}
    onDismissToast={(id) => (toasts = toasts.filter(t => t.id !== id))}
  />
</div>

<style>
  .app-layout {
    display: flex;
    width: 100vw;
    height: 100vh;
    overflow: hidden;
    background: var(--bg-0);
  }

  .main-viewport {
    flex: 1;
    display: flex;
    flex-direction: column;
    height: 100%;
    min-width: 0;
    overflow: hidden;
    position: relative;
  }

  .view-container {
    flex: 1;
    min-height: 0;
    overflow: hidden;
  }
</style>
