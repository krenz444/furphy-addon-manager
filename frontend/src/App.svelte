<script lang="ts">
  import {
    invoke,
    isMockMode,
    installDependencies,
    ignoreDependency,
    unignoreDependency,
    getJobQueueStatus,
    listenJobEvents,
  } from './lib/ipc';
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
  import HoldDialog from './components/dialogs/HoldDialog.svelte';
  import ModifiedDialog from './components/dialogs/ModifiedDialog.svelte';
  import GroupNameDialog from './components/dialogs/GroupNameDialog.svelte';
  import CopyAddonsDialog from './components/dialogs/CopyAddonsDialog.svelte';
  import ActivityView from './views/ActivityView.svelte';
  import JobStatusBar from './components/jobs/JobStatusBar.svelte';
  import JobPanel from './components/jobs/JobPanel.svelte';
  import Toasts, { type ToastItem } from './components/jobs/Toasts.svelte';
  import AppUpdateBanner from './components/banners/AppUpdateBanner.svelte';
  import { initZoomFromSettings, handleZoomKey } from './lib/zoomControl';
  import type {
    Addon,
    Flavour,
    AppInfo,
    Freshness,
    JobProgressEvent,
    JobQueueSnapshot,
    JobRecord,
    QueuedJobDto,
    PatchCompatStatus,
    AppUpdateInfo,
    AddonGroup,
    CopyItemResult,
    InstallOutcome,
  } from './lib/types';
  import {
    summarizeCheck,
    checkSuccessMessage,
    checkFailureMessage,
    describeJobTitle,
    describeQueuedBehind,
    formatFlavourLabel,
    jobHasActionableErrors,
    isRunnerBusyError,
    errorText,
    BUSY_MESSAGE,
    NOTHING_TO_CHECK_MESSAGE,
  } from './lib/checkReport';

  // Navigation State
  let activeView = $state<'my_addons' | 'get_addons' | 'not_built_for_patch' | 'settings' | 'activity'>('my_addons');

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

  // Groups State
  let groups = $state<AddonGroup[]>([]);

  // Preference State
  let currentTheme = $state<string>('tokyo-rain');
  let density = $state<'comfortable' | 'compact'>('comfortable');

  // Running Job & Toasts
  let runningJob = $state<JobRecord | null>(null);
  let activeProgress = $state<JobProgressEvent | null>(null);
  let backendQueuedJobs = $state<QueuedJobDto[]>([]);
  let optimisticQueuedJobs = $state<QueuedJobDto[]>([]);
  let queuedJobs = $derived.by(() => {
    const combined = [...backendQueuedJobs, ...optimisticQueuedJobs];
    return combined.map((item, idx) => ({ ...item, position: idx + 1 }));
  });
  let panelJob = $state<JobRecord | null>(null);
  let panelRetryAction = $state<(() => void) | null>(null);
  let lastFinishedJob = $state<JobRecord | null>(null);
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
  let browseSearchQuery = $state<string>('');
  let addDialogOpen = $state<boolean>(false);
  let exportDialogOpen = $state<boolean>(false);

  // Group Name Dialog State
  let groupDialogOpen = $state<boolean>(false);
  let groupDialogMode = $state<'create' | 'rename'>('create');
  let groupDialogInitialName = $state<string>('');
  let groupDialogError = $state<string | null>(null);
  let groupDialogTargetGroup = $state<AddonGroup | null>(null);
  let groupDialogTargetAddon = $state<Addon | null>(null);

  // Copy Addons Dialog State
  let copyDialogOpen = $state<boolean>(false);
  let copyPreselectedIds = $state<string[]>([]);

  // Confirm Dialog State
  let confirmOpen = $state<boolean>(false);
  let confirmTitle = $state<string>('Are you sure?');
  let confirmMessage = $state<string>('');
  let confirmDetail = $state<string | null>(null);
  let confirmDanger = $state<boolean>(false);
  let confirmAction = $state<(() => void) | null>(null);

  // Hold & Modified Dialog State
  let holdDialogOpen = $state<boolean>(false);
  let holdDialogAddon = $state<Addon | null>(null);
  let modifiedDialogOpen = $state<boolean>(false);
  let modifiedDialogAddon = $state<Addon | null>(null);

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
  // Owned by handleCheckNow alone: a stale "running check" learned from the backend cannot lock out a new click.
  let checkInFlight = $state(false);
  let checkInFlightFlavour = $state<string | null>(null);
  let isJobBusy = $derived(runningJob?.state === 'running' || queuedJobs.length > 0);
  let isChecking = $derived(
    (checkInFlight && (!checkInFlightFlavour || checkInFlightFlavour === activeFlavour)) ||
    (runningJob?.state === 'running' && runningJob.kind === 'check' && (!runningJob.flavour || runningJob.flavour === activeFlavour)) ||
    queuedJobs.some((q) => q.kind === 'check' && (!q.flavour || q.flavour === activeFlavour))
  );

  interface TrackedDispatchToken {
    id: number;
    kind: string;
    flavour: string | null;
    seenFinished: boolean;
  }
  let trackedDispatchSeq = 0;
  const pendingFrontendDispatches: TrackedDispatchToken[] = [];

  function syncLegacyJobFields(job: JobRecord | null, progress: JobProgressEvent | null) {
    if (!job || job.state !== 'running') {
      jobIndex = 0;
      jobTotal = 0;
      return;
    }
    if (progress && progress.job_id === job.id) {
      activeJobPhase = progress.step.phase || describeJobTitle(job.kind, job.flavour, flavours);
      currentJobAddon = progress.step.addon ?? progress.message ?? '';
      jobIndex = progress.step.index;
      jobTotal = progress.step.total;
    } else {
      activeJobPhase = job.kind === 'check' ? 'Checking' : describeJobTitle(job.kind, job.flavour, flavours);
      currentJobAddon = 'Running in the background...';
      jobIndex = 0;
      jobTotal = 0;
    }
  }

  function applyQueueSnapshot(snapshot: JobQueueSnapshot) {
    runningJob = snapshot.active_job ?? null;
    activeProgress = snapshot.active_progress ?? null;
    backendQueuedJobs = Array.isArray(snapshot.queued_jobs) ? snapshot.queued_jobs : [];
    // Drop matched optimistic placeholders once the backend snapshot acknowledges them.
    if (optimisticQueuedJobs.length > 0) {
      const confirmedKinds = new Set(
        [
          ...(snapshot.active_job ? [`${snapshot.active_job.kind}:${snapshot.active_job.flavour ?? ''}`] : []),
          ...backendQueuedJobs.map((q) => `${q.kind}:${q.flavour ?? ''}`),
        ],
      );
      optimisticQueuedJobs = optimisticQueuedJobs.filter(
        (opt) => !confirmedKinds.has(`${opt.kind}:${opt.flavour ?? ''}`),
      );
    }
    syncLegacyJobFields(runningJob, activeProgress);
  }

  function handleJobStartedEvent(job: JobRecord) {
    runningJob = job;
    activeProgress = null;
    if (optimisticQueuedJobs.length > 0) {
      const idx = optimisticQueuedJobs.findIndex(
        (opt) => opt.kind === job.kind && (opt.flavour ?? null) === (job.flavour ?? null),
      );
      if (idx !== -1) {
        optimisticQueuedJobs = optimisticQueuedJobs.filter((_, i) => i !== idx);
      }
    }
    syncLegacyJobFields(job, null);
  }

  function handleJobProgressEvent(ev: JobProgressEvent) {
    if (!runningJob || runningJob.id === ev.job_id || runningJob.state === 'running') {
      activeProgress = ev;
      syncLegacyJobFields(runningJob, ev);
    }
  }

  async function handleJobFinishedEvent(job: JobRecord) {
    lastFinishedJob = job;
    if (runningJob?.id === job.id) {
      runningJob = null;
      activeProgress = null;
      syncLegacyJobFields(null, null);
    }

    const matchingToken = pendingFrontendDispatches.find(
      (t) => !t.seenFinished && t.kind === job.kind && t.flavour === (job.flavour ?? null),
    );
    if (matchingToken) {
      matchingToken.seenFinished = true;
      return;
    }

    // Background / tray / scheduler job completed without an awaiting frontend caller.
    await refreshFlavourData(activeFlavour);
    if (isGameActive && job.reload_needed) {
      reloadNeeded = true;
    }

    const flvLabel = formatFlavourLabel(job.flavour, flavours);
    const prefix = job.flavour && job.flavour !== activeFlavour && flvLabel ? `${flvLabel}: ` : '';
    const hasErrors = jobHasActionableErrors(job.results, job.state, job.error);

    if (hasErrors) {
      if (job.kind === 'check') {
        const summary = summarizeCheck(job);
        const text =
          summary && summary.failed > 0
            ? checkFailureMessage(summary)
            : `Check failed: ${job.error ?? 'unknown error'}`;
        addToast('error', prefix + text, 6000);
      } else {
        handleJobResultToast(job, prefix);
      }
      if (!job.flavour || job.flavour === activeFlavour) {
        panelJob = job;
        panelRetryAction = buildRetryAction(job.kind, job.flavour, job.params);
      }
    } else if (job.kind === 'check') {
      const summary = summarizeCheck(job);
      addToast('success', prefix + (summary ? checkSuccessMessage(summary) : 'Check complete.'));
    }
  }

  $effect(() => {
    let active = true;
    let unlistenFn: (() => void) | null = null;
    listenJobEvents({
      onQueueUpdated: (snapshot) => {
        if (active) applyQueueSnapshot(snapshot);
      },
      onStarted: (job) => {
        if (active) handleJobStartedEvent(job);
      },
      onProgress: (ev) => {
        if (active) handleJobProgressEvent(ev);
      },
      onFinished: (job) => {
        if (active) void handleJobFinishedEvent(job);
      },
    })
      .then((fn) => {
        if (active) {
          unlistenFn = fn;
        } else {
          fn();
        }
      })
      .catch((err) => {
        console.warn('Could not subscribe to job events:', err);
      });

    return () => {
      active = false;
      unlistenFn?.();
    };
  });

  // Bounded fallback poll ONLY while a job is running or queued in case an event is missed.
  $effect(() => {
    const hasActiveWork = runningJob?.state === 'running' || queuedJobs.length > 0;
    if (!hasActiveWork) return;
    const intervalId = setInterval(async () => {
      try {
        const snap = await getJobQueueStatus();
        applyQueueSnapshot(snap);
      } catch {
        // Ignore transient fallback poll failures
      }
    }, 1500);
    return () => clearInterval(intervalId);
  });

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

  function inspectFinishedJob(job: JobRecord): { failedCount: number; failedNames: string[]; errorMessage: string | null } {
    let failedCount = 0;
    const failedNames: string[] = [];
    let errorMessage: string | null = job.error || null;

    if (job.results) {
      try {
        const parsed = typeof job.results === 'string' ? JSON.parse(job.results) : job.results;
        if (parsed) {
          if (typeof parsed.failed === 'number' && parsed.failed > 0) {
            failedCount = parsed.failed;
          }

          const items = Array.isArray(parsed)
            ? parsed
            : Array.isArray(parsed.results)
              ? parsed.results
              : [];

          for (const item of items) {
            if (!item) continue;
            if (item.status === 'Failed' || item.status === 'failed' || item.error) {
              const name = item.name || item.addon_id || 'Unknown Addon';
              if (!failedNames.includes(name)) {
                failedNames.push(name);
              }
              if (!errorMessage && item.error) {
                errorMessage = item.error;
              }
            }
            if (Array.isArray(item.failed)) {
              for (const f of item.failed) {
                const name = typeof f === 'string' ? f : (f?.name || f?.addon_id || 'Unknown Addon');
                if (!failedNames.includes(name)) failedNames.push(name);
                if (!errorMessage && typeof f === 'object' && f?.error) errorMessage = f.error;
              }
            }
          }

          if (Array.isArray(parsed.failed)) {
            for (const f of parsed.failed) {
              const name = typeof f === 'string' ? f : (f?.name || f?.addon_id || 'Unknown Addon');
              if (!failedNames.includes(name)) failedNames.push(name);
              if (!errorMessage && typeof f === 'object' && f?.error) errorMessage = f.error;
            }
          }

          if (failedCount === 0 && failedNames.length > 0) {
            failedCount = failedNames.length;
          }
        }
      } catch {
        // ignore parse error
      }
    }

    if (job.state === 'failed' && failedCount === 0) {
      failedCount = 1;
    }

    return { failedCount, failedNames, errorMessage };
  }

  function handleJobResultToast(job: JobRecord, prefix = ''): boolean {
    const { failedCount, failedNames, errorMessage } = inspectFinishedJob(job);
    if (failedCount > 0 || job.error || job.state === 'failed') {
      const nameStr = failedNames.length > 0 ? failedNames.join(', ') : `${failedCount} addon(s)`;
      const errorSummary = errorMessage ? `: ${errorMessage}` : '';
      addToast('error', `${prefix}Failed updating ${nameStr}${errorSummary}`, 6000);
      return true;
    }
    return false;
  }

  async function refreshGroups() {
    try {
      const list = await invoke<AddonGroup[]>('list_groups');
      groups = Array.isArray(list) ? list : [];
    } catch (err) {
      console.warn('Failed to load groups:', err);
      groups = [];
    }
  }

  async function loadInitialData() {
    try {
      try {
        appInfo = await invoke<AppInfo>('get_app_info');
      } catch {
        appInfo = {
          name: 'Furphy Addon Manager',
          version: '2.0.0',
          is_dev: false,
          identifier: 'krenzcreative.furphy.addonmanager',
        };
      }

      try {
        const s = await invoke<Record<string, any>>('get_settings');
        if (s) {
          await initZoomFromSettings(s);
          if (s.activeFlavour && typeof s.activeFlavour === 'string') {
            activeFlavour = s.activeFlavour;
          }
          if (s.showTestRealms !== undefined) showTestRealms = Boolean(s.showTestRealms);
          if (s.hostTheme) currentTheme = s.hostTheme;
        } else {
          await initZoomFromSettings({});
        }
      } catch {
        await initZoomFromSettings({});
      }

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
        if (u) {
          if (u.first_run_update) {
            addToast('success', `Updated to Furphy Addon Manager v${u.first_run_update}.`);
          }
          if (u.has_update && u.update_version) {
            appUpdate = u;
          }
        }
      } catch {}

      await refreshGroups();
      await refreshFlavourData(activeFlavour);
    } catch (err) {
      console.error('Failed to load initial data:', err);
    }
  }

  async function refreshFlavourData(flavourId: string) {
    try {
      const stateRes = await invoke<{
        addons?: Addon[];
        flavours?: Flavour[];
        freshness?: Freshness;
        running_job?: JobRecord | null;
        active_progress?: JobProgressEvent | null;
        queued_jobs?: QueuedJobDto[];
        untracked_count?: number;
        is_game_active?: boolean;
      }>('get_state', { flavour: flavourId });

      if (stateRes) {
        if (stateRes.flavours && stateRes.flavours.length > 0) {
          flavours = stateRes.flavours;
        }
        if (stateRes.addons) {
          addons = stateRes.addons;
          if (activeDrawerAddon) {
            const currentId = activeDrawerAddon.id;
            const refreshed = addons.find((a) => a.id === currentId);
            if (refreshed) activeDrawerAddon = refreshed;
          }
        }
        if (stateRes.freshness) freshness = stateRes.freshness;
        if (stateRes.running_job !== undefined) {
          runningJob = stateRes.running_job;
          activeProgress = stateRes.active_progress ?? null;
          if (Array.isArray(stateRes.queued_jobs)) {
            backendQueuedJobs = stateRes.queued_jobs;
          }
          syncLegacyJobFields(runningJob, activeProgress);
        }
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
        if (activeDrawerAddon) {
          const currentId = activeDrawerAddon.id;
          const refreshed = addons.find((a) => a.id === currentId);
          if (refreshed) activeDrawerAddon = refreshed;
        }
      } catch {
        addons = [];
      }
    }
  }

  function handleFlavourChange(flavourId: string) {
    activeFlavour = flavourId;
    invoke('update_settings', { key: 'activeFlavour', value: flavourId }).catch((err) => {
      console.warn('Failed to persist activeFlavour setting:', err);
    });
    refreshFlavourData(flavourId);
  }

  function handleThemeChange(theme: string) {
    currentTheme = theme;
    invoke('set_window_theme', { theme }).catch(() => {});
  }

  function handleDensityChange(newDensity: 'comfortable' | 'compact') {
    density = newDensity;
  }

  interface RunTrackedJobRequest {
    kind: string;
    flavour: string | null;
    params?: Record<string, unknown>;
    targetLabel?: string | null;
    logLine?: string;
    executor?: () => Promise<JobRecord>;
  }

  interface RunTrackedJobOptions {
    onRetry?: () => void;
    suppressPanel?: boolean;
  }

  function buildRetryAction(kind: string, flv: string | null, paramsJson: string | null): (() => void) | null {
    const targetFlavour = flv ?? activeFlavour;
    let parsedParams: Record<string, unknown> = {};
    if (paramsJson) {
      try {
        const raw = JSON.parse(paramsJson) as unknown;
        if (raw && typeof raw === 'object' && !Array.isArray(raw)) {
          parsedParams = raw as Record<string, unknown>;
        }
      } catch {
        parsedParams = {};
      }
    }
    if (kind === 'check') {
      return () => {
        void runCheck(targetFlavour);
      };
    }
    if (kind === 'sync' || kind === 'update-all-flavours') {
      return () => {
        void runTrackedJob({
          kind,
          flavour: flv,
          params: parsedParams,
        }).then(() => refreshFlavourData(targetFlavour)).catch((err) => {
          addToast('error', `Retry failed: ${errorText(err)}`);
        });
      };
    }
    if (kind === 'install_dependencies') {
      const addonId = typeof parsedParams.addon_id === 'string' ? parsedParams.addon_id : undefined;
      return () => {
        void handleInstallDeps(addonId);
      };
    }
    return () => {
      void runTrackedJob({
        kind,
        flavour: flv,
        params: parsedParams,
      }).then(() => refreshFlavourData(targetFlavour)).catch((err) => {
        addToast('error', `Retry failed: ${errorText(err)}`);
      });
    };
  }

  async function runTrackedJob(
    req: RunTrackedJobRequest,
    options: RunTrackedJobOptions = {},
  ): Promise<JobRecord> {
    const flv = req.flavour;
    const dispatchId = ++trackedDispatchSeq;
    const token: TrackedDispatchToken = {
      id: dispatchId,
      kind: req.kind,
      flavour: flv,
      seenFinished: false,
    };
    pendingFrontendDispatches.push(token);

    const optQueueId = `opt-${dispatchId}`;
    let busyActive: JobRecord | null = runningJob?.state === 'running' ? runningJob : null;
    try {
      const snap = await getJobQueueStatus();
      applyQueueSnapshot(snap);
      busyActive = snap.active_job ?? null;
    } catch {
      // Proceed with local state if queue probe fails.
    }

    if (busyActive) {
      addToast('info', describeQueuedBehind(busyActive.kind, busyActive.flavour, flavours));
      optimisticQueuedJobs = [
        ...optimisticQueuedJobs,
        {
          queue_id: optQueueId,
          kind: req.kind,
          flavour: flv,
          target_label: req.targetLabel ?? null,
          queued_at: new Date().toISOString(),
          position: queuedJobs.length + 1,
        },
      ];
    } else {
      runningJob = {
        id: `opt-job-${dispatchId}`,
        kind: req.kind,
        flavour: flv,
        params: req.params ? JSON.stringify(req.params) : null,
        state: 'running',
        started_at: new Date().toISOString(),
        finished_at: null,
        error: null,
        results: null,
        reload_needed: isGameActive,
        log_path: null,
      };
      syncLegacyJobFields(runningJob, null);
    }

    if (req.logLine) {
      jobLogs = [req.logLine];
    }

    const retryFn =
      options.onRetry ??
      buildRetryAction(req.kind, flv, req.params ? JSON.stringify(req.params) : null);

    try {
      const job = req.executor
        ? await req.executor()
        : await invoke<JobRecord>('start_job', {
            kind: req.kind,
            flavour: flv,
            params: req.params ?? {},
          });
      const finishedJob: JobRecord = job || {
        id: `job-${req.kind}-${dispatchId}`,
        kind: req.kind,
        flavour: flv,
        params: req.params ? JSON.stringify(req.params) : null,
        state: 'completed',
        started_at: new Date().toISOString(),
        finished_at: new Date().toISOString(),
        error: null,
        results: null,
        reload_needed: false,
        log_path: null,
      };
      lastFinishedJob = finishedJob;
      if (runningJob?.id === `opt-job-${dispatchId}` || runningJob?.id === finishedJob.id) {
        runningJob = null;
        activeProgress = null;
        syncLegacyJobFields(null, null);
      }
      if (!options.suppressPanel) {
        const hasErrors = jobHasActionableErrors(finishedJob.results, finishedJob.state, finishedJob.error);
        if (hasErrors && (!finishedJob.flavour || finishedJob.flavour === activeFlavour)) {
          panelJob = finishedJob;
          panelRetryAction = retryFn;
        } else if (!hasErrors && panelJob?.kind === req.kind && panelJob?.flavour === flv) {
          panelJob = null;
          panelRetryAction = null;
        }
      }
      if (isGameActive && finishedJob.reload_needed) {
        reloadNeeded = true;
      }
      return finishedJob;
    } catch (err: unknown) {
      const message = errorText(err);
      const failedRecord: JobRecord = {
        id: `opt-job-${dispatchId}`,
        kind: req.kind,
        flavour: flv,
        params: req.params ? JSON.stringify(req.params) : null,
        state: 'failed',
        started_at: new Date().toISOString(),
        finished_at: new Date().toISOString(),
        error: message,
        results: null,
        reload_needed: false,
        log_path: null,
      };
      lastFinishedJob = failedRecord;
      if (runningJob?.id === `opt-job-${dispatchId}`) {
        runningJob = null;
        activeProgress = null;
        syncLegacyJobFields(null, null);
      }
      if (!options.suppressPanel && (!flv || flv === activeFlavour)) {
        panelJob = failedRecord;
        panelRetryAction = retryFn;
      }
      throw err;
    } finally {
      optimisticQueuedJobs = optimisticQueuedJobs.filter((q) => q.queue_id !== optQueueId);
      const tokIdx = pendingFrontendDispatches.findIndex((t) => t.id === dispatchId);
      if (tokIdx !== -1) pendingFrontendDispatches.splice(tokIdx, 1);
    }
  }

  // Job Triggers
  async function handleCheckNow() {
    const targetFlavour = activeFlavour;
    if (addons.length === 0) {
      addToast('info', NOTHING_TO_CHECK_MESSAGE);
      return;
    }
    if (checkInFlight && checkInFlightFlavour === targetFlavour) return;
    checkInFlight = true;
    checkInFlightFlavour = targetFlavour;
    try {
      if (runningJob?.state === 'running' || queuedJobs.length > 0) {
        // Re-read the live queue to distinguish a stale DB job (Test 13) from an active check/job.
        const snap = await getJobQueueStatus();
        applyQueueSnapshot(snap);
        const alreadyCheckingSameFlavour =
          (snap.active_job?.kind === 'check' && (snap.active_job.flavour ?? targetFlavour) === targetFlavour) ||
          snap.queued_jobs.some((q) => q.kind === 'check' && (q.flavour ?? targetFlavour) === targetFlavour);
        if (alreadyCheckingSameFlavour) {
          return;
        }
      }
      await runCheck(targetFlavour);
    } finally {
      checkInFlight = false;
      checkInFlightFlavour = null;
    }
  }

  async function runCheck(targetFlavour = activeFlavour) {
    const flv = targetFlavour;
    const flvLabel = flavours.find((f) => f.id === flv)?.label ?? flv;
    let finishedJob: JobRecord;
    try {
      finishedJob = await runTrackedJob(
        {
          kind: 'check',
          flavour: flv,
          logLine: '[Check] Starting check for ' + flv,
        },
        {
          onRetry: () => {
            void runCheck(flv);
          },
        },
      );
    } catch (err: unknown) {
      const message = errorText(err);
      if (isRunnerBusyError(message)) {
        addToast('info', BUSY_MESSAGE);
        await refreshFlavourData(activeFlavour);
      } else {
        addToast('error', `Check failed: ${message}`);
      }
      return;
    }

    const summary = summarizeCheck(finishedJob);
    const failed = finishedJob.state === 'failed' || !!finishedJob.error || (summary?.failed ?? 0) > 0;
    // A check can finish while the user is already on another game version.
    const prefix = flv === activeFlavour ? '' : `${flvLabel}: `;
    if (failed) {
      const text =
        summary && summary.failed > 0 ? checkFailureMessage(summary) : `Check failed: ${finishedJob.error ?? 'unknown error'}`;
      addToast('error', prefix + text, 6000);
    } else {
      addToast('success', prefix + (summary ? checkSuccessMessage(summary) : 'Check complete.'));
    }
    await refreshFlavourData(activeFlavour);
    if (failed && flv === activeFlavour) {
      panelJob = finishedJob;
      panelRetryAction = () => {
        void runCheck(flv);
      };
    }
  }

  async function handleUpdateAll() {
    const targetFlavour = activeFlavour;
    const flvLabel = flavours.find((f) => f.id === targetFlavour)?.label ?? targetFlavour;
    try {
      const finishedJob = await runTrackedJob(
        {
          kind: 'sync',
          flavour: targetFlavour,
          logLine: '[Sync] Updating all eligible addons for ' + targetFlavour,
        },
        {
          onRetry: () => {
            void handleUpdateAll();
          },
        },
      );
      const prefix = targetFlavour === activeFlavour ? '' : `${flvLabel}: `;
      const hasError = handleJobResultToast(finishedJob, prefix);
      if (!hasError) {
        addToast('success', `${prefix}All addons updated successfully.`);
      }
      await refreshFlavourData(activeFlavour);
    } catch (err: unknown) {
      addToast('error', 'Update failed: ' + errorText(err));
    }
  }

  async function handleInstallDeps(addonId?: string) {
    const targetFlavour = activeFlavour;
    const targetAddon = addonId ? addons.find((a) => a.id === addonId) : null;
    const targetName = targetAddon?.name ?? addonId;
    try {
      const finishedJob = await runTrackedJob(
        {
          kind: 'install_dependencies',
          flavour: targetFlavour,
          params: { addon_id: addonId ?? null },
          targetLabel: targetName ?? null,
          logLine: `[Dependencies] Starting dependency installation for ${targetName ?? 'all addons in ' + targetFlavour}`,
          executor: () => installDependencies(targetFlavour, addonId),
        },
        {
          onRetry: () => {
            void handleInstallDeps(addonId);
          },
        },
      );
      const hasJobError = handleJobResultToast(finishedJob);

      let unresolved: string[] = [];
      if (finishedJob?.results) {
        try {
          const parsed = typeof finishedJob.results === 'string' ? JSON.parse(finishedJob.results) : finishedJob.results;
          if (Array.isArray(parsed)) {
            for (const item of parsed) {
              if (Array.isArray(item.unresolved_deps)) unresolved.push(...item.unresolved_deps);
            }
          } else if (Array.isArray(parsed?.unresolved_deps)) {
            unresolved.push(...parsed.unresolved_deps);
          }
        } catch {
          // ignore parse error
        }
      }

      await refreshFlavourData(activeFlavour);

      if (unresolved.length === 0) {
        if (addonId) {
          const target = addons.find((a) => a.id === addonId);
          if (target?.missing_deps && target.missing_deps.length > 0) {
            unresolved = [...target.missing_deps];
          }
        }
      }

      if (!hasJobError) {
        if (unresolved.length > 0) {
          addToast(
            'warning',
            `Could not automatically resolve: ${unresolved.join(', ')}. You can ignore or search for them.`
          );
        } else {
          addToast(
            'success',
            targetName
              ? `Installed missing dependencies for ${targetName}`
              : 'All missing dependencies installed successfully.'
          );
        }
      }
    } catch (err: unknown) {
      addToast('error', 'Dependency installation failed: ' + errorText(err));
    }
  }

  async function handleIgnoreDep(addonId: string, depName: string) {
    try {
      await ignoreDependency(addonId, depName);
      addToast('success', `Ignored dependency '${depName}'.`);
      await refreshFlavourData(activeFlavour);
    } catch (err) {
      addToast('error', `Failed to ignore dependency '${depName}': ${err}`);
    }
  }

  async function handleUnignoreDep(addonId: string, depName: string) {
    try {
      await unignoreDependency(addonId, depName);
      addToast('info', `Restored dependency warning for '${depName}'.`);
      await refreshFlavourData(activeFlavour);
    } catch (err) {
      addToast('error', `Failed to un-ignore dependency '${depName}': ${err}`);
    }
  }

  function handleSearchDep(query: string) {
    browseSearchQuery = query;
    activeView = 'get_addons';
    activeDrawerAddon = null;
  }

  async function handleIgnoreAllDeps(addon: Addon) {
    if (!addon.missing_deps || addon.missing_deps.length === 0) return;
    try {
      for (const dep of addon.missing_deps) {
        await ignoreDependency(addon.id, dep);
      }
      addToast('success', `Ignored missing dependencies for ${addon.name ?? addon.id}.`);
      await refreshFlavourData(activeFlavour);
    } catch (err) {
      addToast('error', `Failed to ignore dependencies: ${err}`);
    }
  }

  async function handleIgnoreAllMissing() {
    const addonsWithDeps = addons.filter((a) => a.missing_deps && a.missing_deps.length > 0);
    if (addonsWithDeps.length === 0) return;
    try {
      for (const addon of addonsWithDeps) {
        if (addon.missing_deps) {
          for (const dep of addon.missing_deps) {
            await ignoreDependency(addon.id, dep);
          }
        }
      }
      addToast('success', 'Ignored all missing dependencies.');
      await refreshFlavourData(activeFlavour);
    } catch (err) {
      addToast('error', `Failed to ignore missing dependencies: ${err}`);
    }
  }

  async function handleHoldUpdateAnyway(addon: Addon) {
    holdDialogOpen = false;
    const flv = activeFlavour;
    try {
      const finishedJob = await runTrackedJob({
        kind: 'sync',
        flavour: flv,
        params: { only: [addon.id], override_hold: true },
        targetLabel: addon.name ?? addon.id,
        logLine: `[Sync] Updating ${addon.name ?? addon.id} (override hold)`,
      });
      const hasError = handleJobResultToast(finishedJob);
      if (!hasError) {
        addToast('info', `Updating ${addon.name ?? addon.id}`);
      }
      await refreshFlavourData(activeFlavour);
    } catch (err) {
      addToast('error', `Update failed: ${errorText(err)}`);
    }
  }

  async function handleHoldIgnoreForBuild(addon: Addon, build: string) {
    holdDialogOpen = false;
    try {
      await invoke('hold_ignore_for_build', { addon_id: addon.id, build });
      addToast('info', `Ignored updates for ${addon.name ?? addon.id} on build ${build}`);
      await refreshFlavourData(activeFlavour);
    } catch (err) {
      addToast('error', `Failed to ignore build: ${errorText(err)}`);
    }
  }

  async function handleModifiedUpdateAndZip(addon: Addon) {
    modifiedDialogOpen = false;
    const flv = activeFlavour;
    try {
      const finishedJob = await runTrackedJob({
        kind: 'sync',
        flavour: flv,
        params: { only: [addon.id], backup_modified: true, override_modified: true },
        targetLabel: addon.name ?? addon.id,
        logLine: `[Sync] Backing up and updating ${addon.name ?? addon.id}`,
      });
      const hasError = handleJobResultToast(finishedJob);
      if (!hasError) {
        addToast('info', `Updating and backing up local copy for ${addon.name ?? addon.id}`);
      }
      await refreshFlavourData(activeFlavour);
    } catch (err) {
      addToast('error', `Update failed: ${errorText(err)}`);
    }
  }

  async function handleModifiedUpdateAnyway(addon: Addon) {
    modifiedDialogOpen = false;
    const flv = activeFlavour;
    try {
      const finishedJob = await runTrackedJob({
        kind: 'sync',
        flavour: flv,
        params: { only: [addon.id], override_modified: true },
        targetLabel: addon.name ?? addon.id,
        logLine: `[Sync] Updating ${addon.name ?? addon.id} (override modified)`,
      });
      const hasError = handleJobResultToast(finishedJob);
      if (!hasError) {
        addToast('info', `Updating ${addon.name ?? addon.id}`);
      }
      await refreshFlavourData(activeFlavour);
    } catch (err) {
      addToast('error', `Update failed: ${errorText(err)}`);
    }
  }

  async function handleSetChannel(addon: Addon, channel: number) {
    try {
      await invoke('set_release_channel', { addon_id: addon.id, release_type: channel });
      addToast('info', `Set ${addon.name ?? addon.id} channel to ${channel === 1 ? 'Stable' : channel === 2 ? 'Beta' : 'Alpha'}`);
      await refreshFlavourData(activeFlavour);
    } catch (err) {
      addToast('error', `Failed to set release channel: ${errorText(err)}`);
    }
  }

  async function handleToggleAutoUpdate(addon: Addon) {
    const nextVal = !(addon.auto_update ?? true);
    try {
      await invoke('set_auto_update', { addon_id: addon.id, auto_update: nextVal });
      addToast('info', `${nextVal ? 'Enabled' : 'Disabled'} auto-update for ${addon.name ?? addon.id}`);
      await refreshFlavourData(activeFlavour);
    } catch (err) {
      addToast('error', `Failed to toggle auto-update: ${errorText(err)}`);
    }
  }

  async function handleShowFolder(addon: Addon) {
    try {
      await invoke('show_addon_folder', { flavour: activeFlavour, addon_id: addon.id });
    } catch (err) {
      addToast('error', `Failed to show folder: ${errorText(err)}`);
    }
  }

  async function handleReinstall(addon: Addon) {
    const flv = activeFlavour;
    try {
      const finishedJob = await runTrackedJob({
        kind: 'reinstall',
        flavour: flv,
        params: { addon_id: addon.id },
        targetLabel: addon.name ?? addon.id,
        logLine: `[Reinstall] Reinstalling ${addon.name ?? addon.id}`,
      });
      const hasError = handleJobResultToast(finishedJob);
      if (!hasError) {
        addToast('info', `Reinstalling ${addon.name ?? addon.id}`);
      }
      await refreshFlavourData(activeFlavour);
    } catch (err) {
      addToast('error', `Reinstall failed: ${errorText(err)}`);
    }
  }

  async function handleBulkSetChannel(targetAddons: Addon[], channel: number) {
    for (const a of targetAddons) {
      await invoke('set_release_channel', { addon_id: a.id, release_type: channel }).catch(() => {});
    }
    addToast('info', `Updated release channel for ${targetAddons.length} addons`);
    await refreshFlavourData(activeFlavour);
  }

  async function handleBulkSetAutoUpdate(targetAddons: Addon[], autoUpdate: boolean) {
    for (const a of targetAddons) {
      await invoke('set_auto_update', { addon_id: a.id, auto_update: autoUpdate }).catch(() => {});
    }
    addToast('info', `Updated auto-update for ${targetAddons.length} addons`);
    await refreshFlavourData(activeFlavour);
  }

  async function handleToggleFavourite(addon: Addon) {
    const nextFav = !(addon.favourite ?? false);
    try {
      await invoke('set_favourite', { addon_id: addon.id, favourite: nextFav });
      await refreshFlavourData(activeFlavour);
    } catch (err) {
      addToast('error', `Failed to update favourite: ${errorText(err)}`);
    }
  }

  async function handleToggleGroup(addon: Addon, groupId: string, member: boolean) {
    try {
      await invoke('set_addon_group', { addon_id: addon.id, group_id: groupId, member });
      await refreshGroups();
      await refreshFlavourData(activeFlavour);
    } catch (err) {
      addToast('error', `Failed to update group: ${errorText(err)}`);
    }
  }

  function handleRequestNewGroup(addon: Addon | null) {
    groupDialogMode = 'create';
    groupDialogInitialName = '';
    groupDialogError = null;
    groupDialogTargetGroup = null;
    groupDialogTargetAddon = addon;
    groupDialogOpen = true;
  }

  function handleRequestRenameGroup(group: AddonGroup) {
    groupDialogMode = 'rename';
    groupDialogInitialName = group.name;
    groupDialogError = null;
    groupDialogTargetGroup = group;
    groupDialogTargetAddon = null;
    groupDialogOpen = true;
  }

  function handleRequestDeleteGroup(group: AddonGroup) {
    confirmTitle = 'Delete Group';
    confirmMessage = `Are you sure you want to delete the group "${group.name}"?`;
    confirmDetail = 'The addons in this group will not be uninstalled or deleted.';
    confirmDanger = true;
    confirmAction = async () => {
      try {
        await invoke('delete_group', { group_id: group.id });
        await refreshGroups();
        await refreshFlavourData(activeFlavour);
      } catch (err) {
        addToast('error', `Failed to delete group: ${errorText(err)}`);
      }
      confirmOpen = false;
    };
    confirmOpen = true;
  }

  async function handleSaveGroupName(name: string) {
    groupDialogError = null;
    try {
      if (groupDialogMode === 'create') {
        const created = await invoke<AddonGroup>('create_group', { name });
        if (groupDialogTargetAddon && created?.id) {
          await invoke('set_addon_group', {
            addon_id: groupDialogTargetAddon.id,
            group_id: created.id,
            member: true,
          });
        }
        groupDialogOpen = false;
        await refreshGroups();
        await refreshFlavourData(activeFlavour);
      } else if (groupDialogMode === 'rename' && groupDialogTargetGroup) {
        await invoke('rename_group', { group_id: groupDialogTargetGroup.id, name });
        groupDialogOpen = false;
        await refreshGroups();
        await refreshFlavourData(activeFlavour);
      }
    } catch (err) {
      groupDialogError = errorText(err);
    }
  }

  function handleOpenCopyAddons(selectedIds: string[] = []) {
    copyPreselectedIds = selectedIds;
    copyDialogOpen = true;
  }

  async function handleCopyRun(targetFlavour: string, addonIds: string[]): Promise<CopyItemResult[]> {
    const sourceFlavour = activeFlavour;
    try {
      const finishedJob = await runTrackedJob({
        kind: 'copy-addons',
        flavour: sourceFlavour,
        params: { target_flavour: targetFlavour, addon_ids: addonIds },
        targetLabel: `${addonIds.length} addons`,
        logLine: `[Copy] Copying ${addonIds.length} addons from ${sourceFlavour} to ${targetFlavour}`,
      });

      if (finishedJob.state === 'failed' || finishedJob.error) {
        const inspection = inspectFinishedJob(finishedJob);
        const errMsg = inspection.errorMessage || finishedJob.error || 'Copy addons failed';
        throw new Error(errMsg);
      }

      let items: CopyItemResult[] = [];
      if (finishedJob.results) {
        try {
          const parsed = typeof finishedJob.results === 'string' ? JSON.parse(finishedJob.results) : finishedJob.results;
          if (parsed && Array.isArray(parsed.items)) {
            items = parsed.items;
          } else if (Array.isArray(parsed)) {
            items = parsed;
          }
        } catch {}
      }

      await refreshFlavourData(targetFlavour);
      return items;
    } catch (err) {
      throw new Error(errorText(err));
    }
  }

  async function handleUpdateAddon(addon: Addon) {
    const targetFlavour = activeFlavour;
    try {
      const finishedJob = await runTrackedJob({
        kind: 'sync',
        flavour: targetFlavour,
        params: { addon_ids: [addon.id] },
        targetLabel: addon.name ?? addon.id,
        logLine: `[Sync] Updating ${addon.name ?? addon.id}`,
      });
      const hasError = handleJobResultToast(finishedJob);
      if (!hasError) {
        addToast('success', `Updated ${addon.name ?? addon.id}`);
      }
      await refreshFlavourData(activeFlavour);
    } catch (err) {
      addToast('error', `Failed to update ${addon.name ?? addon.id}: ${errorText(err)}`);
    }
  }

  async function handleUpdateSelected(selected: Addon[]) {
    if (selected.length === 0) return;
    const targetFlavour = activeFlavour;
    try {
      const ids = selected.map(a => a.id);
      const finishedJob = await runTrackedJob({
        kind: 'sync',
        flavour: targetFlavour,
        params: { addon_ids: ids },
        targetLabel: `${selected.length} addons`,
        logLine: `[Sync] Updating ${selected.length} selected addons`,
      });
      const hasError = handleJobResultToast(finishedJob);
      if (!hasError) {
        addToast('success', `Updated ${selected.length} addons`);
      }
      await refreshFlavourData(activeFlavour);
    } catch (err) {
      addToast('error', `Bulk update failed: ${errorText(err)}`);
    }
  }

  function handleUninstallAddon(addon: Addon) {
    confirmTitle = 'Uninstall Addon';
    confirmMessage = `Are you sure you want to uninstall "${addon.name ?? addon.id}"?`;
    confirmDetail = `This will remove the package folders from your Interface\\AddOns directory:\n${addon.folders.join('\n')}\nYour SavedVariables settings will be preserved.`;
    confirmDanger = true;
    confirmAction = async () => {
      confirmOpen = false;
      try {
        const finishedJob = await runTrackedJob({
          kind: 'remove',
          flavour: activeFlavour,
          params: { addon_id: addon.id },
          targetLabel: addon.name ?? addon.id,
          logLine: `[Remove] Uninstalling ${addon.name ?? addon.id}`,
        });
        const hasError = handleJobResultToast(finishedJob);
        if (!hasError) {
          addToast('info', `Uninstalled ${addon.name ?? addon.id}`);
        }
        await refreshFlavourData(activeFlavour);
      } catch (err) {
        addToast('error', `Uninstall failed: ${errorText(err)}`);
      }
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
      confirmOpen = false;
      const targetFlavour = activeFlavour;
      let failures = 0;
      for (const addon of selected) {
        try {
          const finishedJob = await runTrackedJob({
            kind: 'remove',
            flavour: targetFlavour,
            params: { addon_id: addon.id },
            targetLabel: addon.name ?? addon.id,
            logLine: `[Remove] Uninstalling ${addon.name ?? addon.id}`,
          });
          if (jobHasActionableErrors(finishedJob.results, finishedJob.state, finishedJob.error)) {
            failures += 1;
          }
        } catch {
          failures += 1;
        }
      }
      if (failures === 0) {
        addToast('info', `Uninstalled ${selected.length} addons`);
      } else {
        addToast('error', `Uninstalled ${selected.length - failures} of ${selected.length} addons (${failures} failed)`);
      }
      await refreshFlavourData(activeFlavour);
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

  async function handleAddAddon(target: string, destinationFlavour?: string): Promise<InstallOutcome> {
    const targetFlavour = destinationFlavour || activeFlavour;
    try {
      const finishedJob = await runTrackedJob({
        kind: 'add',
        flavour: targetFlavour,
        params: { target },
        targetLabel: target,
        logLine: `[Add] Installing addon ${target} to ${targetFlavour}`,
      });
      const hasError = handleJobResultToast(finishedJob);
      const flvLabel = flavours.find(f => f.id === targetFlavour)?.label || targetFlavour;
      if (!hasError) {
        addToast('success', `[${flvLabel}] Addon installed successfully`);
      }
      await refreshFlavourData(targetFlavour);
      if (targetFlavour !== activeFlavour) {
        activeFlavour = targetFlavour;
      }

      if (hasError) {
        const inspection = inspectFinishedJob(finishedJob);
        const failureMessage = inspection.errorMessage || finishedJob.error || 'Installation failed';
        return { ok: false, message: failureMessage };
      }
      return { ok: true, message: 'Addon installed' };
    } catch (err) {
      addToast('error', `Installation failed: ${errorText(err)}`);
      return { ok: false, message: errorText(err) };
    }
  }

  async function handleInstallZip(source: string, destinationFlavour?: string): Promise<InstallOutcome> {
    const targetFlavour = destinationFlavour || activeFlavour;
    const flvLabel = flavours.find(f => f.id === targetFlavour)?.label || targetFlavour;
    try {
      const finishedJob = await runTrackedJob({
        kind: 'install-zip',
        flavour: targetFlavour,
        params: { source },
        targetLabel: source,
        logLine: `[Zip] Installing from ${source} to ${targetFlavour}`,
      });

      if (finishedJob.state === 'failed' || finishedJob.error) {
        const inspection = inspectFinishedJob(finishedJob);
        const failureMsg = inspection.errorMessage || finishedJob.error || 'Failed to install zip';
        await refreshFlavourData(targetFlavour);
        return { ok: false, message: failureMsg };
      }

      let parsed: any = null;
      if (finishedJob.results) {
        try {
          parsed = typeof finishedJob.results === 'string' ? JSON.parse(finishedJob.results) : finishedJob.results;
        } catch {}
      }

      let message = 'Installed zip addon';
      if (parsed) {
        const name = parsed.name || parsed.addon_id || 'addon';
        const versionStr = parsed.version ? ` ${parsed.version}` : '';
        const folders = Array.isArray(parsed.folders) && parsed.folders.length > 0 ? `: ${parsed.folders.join(', ')}` : '';
        message = `Installed ${name}${versionStr} into ${flvLabel}${folders}`;
        if (parsed.replaced) {
          message += '. Replaced the previous copy.';
        }
      }

      await refreshFlavourData(targetFlavour);
      return { ok: true, message };
    } catch (err) {
      await refreshFlavourData(targetFlavour);
      return { ok: false, message: errorText(err) };
    }
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
      confirmOpen = false;
      try {
        const finishedJob = await runTrackedJob({
          kind: 'rollback',
          flavour: activeFlavour,
          params: { addon_id: addon.id },
          targetLabel: addon.name ?? addon.id,
          logLine: `[Rollback] Rolling back ${addon.name ?? addon.id}`,
        });
        const hasError = handleJobResultToast(finishedJob);
        if (!hasError) {
          addToast('success', `Rolled back ${addon.name ?? addon.id}`);
        }
        await refreshFlavourData(activeFlavour);
      } catch (err) {
        addToast('error', `Rollback failed: ${errorText(err)}`);
      }
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

  async function handleProtocolConsent(flavour: string, addonId: number, fileId?: number | null) {
    protocolOpen = false;
    const existing = addons.find(a => a.project_id === addonId || a.id === String(addonId));
    const kind = existing ? 'install' : 'add';
    const params = existing
      ? { addon_id: existing.id, project_id: addonId, file_id: fileId }
      : { target: `curse:${addonId}`, file_id: fileId };
    try {
      const finishedJob = await runTrackedJob({
        kind,
        flavour,
        params,
        targetLabel: existing?.name ?? `Addon #${addonId}`,
        logLine: `[Protocol] Installing addon #${addonId}`,
      });
      const hasError = handleJobResultToast(finishedJob);
      if (!hasError) {
        addToast('success', `Installed addon #${addonId}`);
      }
      await refreshFlavourData(activeFlavour);
    } catch (err) {
      addToast('error', `Protocol install failed: ${errorText(err)}`);
    }
  }

  loadInitialData();
</script>

<svelte:window
  onkeydown={(e) => {
    if (handleZoomKey(e)) {
      e.preventDefault();
    }
  }}
/>

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
    {isChecking}
    onSelectView={(v) => (activeView = v)}
    onSelectFlavour={handleFlavourChange}
    onCheckNow={handleCheckNow}
    onUpdateAll={handleUpdateAll}
  />

  <main class="main-viewport">
    <JobStatusBar
      activeJob={runningJob}
      {activeProgress}
      {queuedJobs}
      {flavours}
      {lastFinishedJob}
      onDismissFinished={() => (lastFinishedJob = null)}
      onOpenLog={() => invoke('open_target', { what: 'lastrun', args: [] })}
    />

    {#if panelJob && (!panelJob.flavour || panelJob.flavour === activeFlavour)}
      <JobPanel
        job={panelJob}
        activePhase={activeJobPhase}
        currentAddon={currentJobAddon}
        progressIndex={jobIndex}
        progressTotal={jobTotal}
        logs={jobLogs}
        onRetry={panelRetryAction ?? undefined}
        onDismiss={() => {
          panelJob = null;
          panelRetryAction = null;
        }}
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
          flavourLabel={flavours.find((f) => f.id === activeFlavour)?.label ?? activeFlavour}
          {density}
          {untrackedCount}
          checkedAt={freshness?.checked_at ?? null}
          {isChecking}
          {isJobBusy}
          {groups}
          onToggleFavourite={handleToggleFavourite}
          onToggleGroup={handleToggleGroup}
          onRequestNewGroup={handleRequestNewGroup}
          onRequestRenameGroup={handleRequestRenameGroup}
          onRequestDeleteGroup={handleRequestDeleteGroup}
          copyAvailable={flavours.some(f => f.installed && f.id !== activeFlavour)}
          onCopyAddons={handleOpenCopyAddons}
          onCheckNow={handleCheckNow}
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
          onInstallDeps={handleInstallDeps}
          onIgnoreDeps={handleIgnoreAllDeps}
          onIgnoreAllMissing={handleIgnoreAllMissing}
          onShowHoldDialog={(addon) => {
            holdDialogAddon = addon;
            holdDialogOpen = true;
          }}
          onShowModifiedDialog={(addon) => {
            modifiedDialogAddon = addon;
            modifiedDialogOpen = true;
          }}
          onSetChannel={handleSetChannel}
          onToggleAutoUpdate={handleToggleAutoUpdate}
          onShowFolder={handleShowFolder}
          onReinstall={handleReinstall}
          onBulkSetChannel={handleBulkSetChannel}
          onBulkSetAutoUpdate={handleBulkSetAutoUpdate}
        />
      {:else if activeView === 'get_addons'}
        <GetAddonsView
          flavour={activeFlavour}
          {flavours}
          flavourLabel={flavours.find(f => f.id === activeFlavour)?.label || activeFlavour}
          initialSearchQuery={browseSearchQuery}
          installedAddons={addons}
          onSelectFlavour={handleFlavourChange}
          onInstallWago={(slug, flv) => handleAddAddon(`https://addons.wago.io/addons/${slug}`, flv || activeFlavour)}
          onInstallCurseForge={(target, flv) => handleAddAddon(String(target), flv || activeFlavour)}
          onInstallGitHub={(repoUrl, flv) => handleAddAddon(repoUrl, flv || activeFlavour)}
          onInstallTukui={(slug, flv) => handleAddAddon('tukui:' + slug, flv || activeFlavour)}
          onInstallZip={handleInstallZip}
        />
      {:else if activeView === 'not_built_for_patch'}
        <NotBuiltForPatchView
          flavour={activeFlavour}
          {addons}
          {compatList}
          onCheckNow={async (addonId) => {
            const targetAddon = addons.find((a) => a.id === addonId);
            const flv = activeFlavour;
            try {
              const finishedJob = await runTrackedJob({
                kind: 'check',
                flavour: flv,
                params: { addon_ids: [addonId] },
                targetLabel: targetAddon?.name ?? addonId,
                logLine: `[Check] Checking ${targetAddon?.name ?? addonId}`,
              });
              const summary = summarizeCheck(finishedJob);
              if (finishedJob.state === 'failed' || finishedJob.error || (summary?.failed ?? 0) > 0) {
                addToast('error', `Check failed for ${targetAddon?.name ?? addonId}: ${finishedJob.error ?? 'unknown error'}`);
              } else {
                addToast('success', summary ? checkSuccessMessage(summary) : `Checked ${targetAddon?.name ?? addonId}`);
              }
              await refreshFlavourData(activeFlavour);
            } catch (err) {
              addToast('error', `Check failed: ${errorText(err)}`);
            }
          }}
          onUpdate={handleUpdateAddon}
          onPin={handleTogglePin}
          onOpenWeb={handleOpenSource}
        />
      {:else if activeView === 'settings'}
        <SettingsView
          flavour={activeFlavour}
          {flavours}
          {currentTheme}
          {density}
          {isGameActive}
          onThemeChange={handleThemeChange}
          onDensityChange={handleDensityChange}
          onExportList={() => (exportDialogOpen = true)}
          onImportList={handleImportAddonList}
          onToast={addToast}
          onRunJob={(req) =>
            runTrackedJob({
              kind: req.kind,
              flavour: req.flavour,
              params: req.params,
              targetLabel: req.label ?? null,
            })
          }
          onUntrackedChange={async () => {
            await refreshFlavourData(activeFlavour);
          }}
          onFlavoursChange={async () => {
            await refreshFlavourData(activeFlavour);
          }}
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
      {:else if activeView === 'activity'}
        <ActivityView
          {activeFlavour}
          onOpenDrawer={(addonId, tab) => {
            const addon = addons.find((a) => a.id === addonId) ?? null;
            if (addon) {
              activeDrawerAddon = addon;
              activeDrawerTab = tab || 'overview';
            }
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
        const flv = activeFlavour;
        try {
          const finishedJob = await runTrackedJob({
            kind: 'install',
            flavour: flv,
            params: { addon_id: addon.id, project_id: addon.project_id, file_id: fileId },
            targetLabel: addon.name ?? addon.id,
            logLine: `[Install] Installing ${addon.name ?? addon.id} version ${fileId}`,
          });
          const hasError = handleJobResultToast(finishedJob);
          if (!hasError) {
            addToast('success', `Installed version ${fileId}`);
          }
          await refreshFlavourData(activeFlavour);
        } catch (err) {
          addToast('error', `Version install failed: ${errorText(err)}`);
        }
      }}
      onPinVersion={async (addon, fileId) => {
        await invoke('pin_version', { id: addon.id, file_id: fileId });
        addToast('info', `Pinned to version ${fileId}`);
        await refreshFlavourData(activeFlavour);
      }}
      onInstallDeps={handleInstallDeps}
      onIgnoreDep={handleIgnoreDep}
      onUnignoreDep={handleUnignoreDep}
      onSearchDep={handleSearchDep}
    />
  {/if}

  <!-- Overlays & Modals -->
  <AddAddonDialog
    isOpen={addDialogOpen}
    {activeFlavour}
    {flavours}
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

  <HoldDialog
    open={holdDialogOpen}
    addon={holdDialogAddon}
    clientBuild={flavours.find((f) => f.id === activeFlavour)?.client_build ?? ''}
    onUpdateAnyway={handleHoldUpdateAnyway}
    onIgnoreForBuild={handleHoldIgnoreForBuild}
    onCancel={() => (holdDialogOpen = false)}
  />

  <ModifiedDialog
    open={modifiedDialogOpen}
    addon={modifiedDialogAddon}
    onUpdateAndZip={handleModifiedUpdateAndZip}
    onUpdateAnyway={handleModifiedUpdateAnyway}
    onSkip={() => (modifiedDialogOpen = false)}
  />

  <GroupNameDialog
    open={groupDialogOpen}
    mode={groupDialogMode}
    initialName={groupDialogInitialName}
    error={groupDialogError}
    onSave={handleSaveGroupName}
    onCancel={() => (groupDialogOpen = false)}
  />

  <CopyAddonsDialog
    open={copyDialogOpen}
    sourceFlavour={activeFlavour}
    {flavours}
    {addons}
    preselectedIds={copyPreselectedIds}
    onClose={() => (copyDialogOpen = false)}
    onRun={handleCopyRun}
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
    min-height: 0;
    overflow: hidden;
    position: relative;
  }

  .view-container {
    flex: 1;
    display: flex;
    flex-direction: column;
    height: 100%;
    min-height: 0;
    overflow: hidden;
  }
</style>
