<script lang="ts">
	import { onMount } from 'svelte';
	import { CheckCircle2, Cpu, Download, Loader2, RefreshCw, Search, XCircle } from '@lucide/svelte';
	import { Button } from '$lib/components/ui/button';
	import { buildProxiedHeaders, buildProxiedUrl } from '$lib/utils';

	type LlmfitSystem = {
		node?: { name?: string; os?: string };
		system?: {
			available_ram_gb?: number;
			backend?: string;
			cpu_cores?: number;
			cpu_name?: string;
			gpu_name?: string;
			gpu_vram_gb?: number;
			total_ram_gb?: number;
			unified_memory?: boolean;
		};
	};

	type LlmfitModel = {
		name: string;
		provider?: string;
		parameter_count?: string;
		fit_label?: string;
		fit_level?: string;
		run_mode_label?: string;
		runtime_label?: string;
		score?: number;
		estimated_tps?: number;
		utilization_pct?: number;
		context_length?: number;
		release_date?: string | null;
		memory_required_gb?: number;
		best_quant?: string;
		use_case?: string;
		gguf_sources?: { provider?: string; repo?: string }[];
	};

	type LlmfitModelsResponse = LlmfitSystem & {
		total_models?: number;
		returned_models?: number;
		models?: LlmfitModel[];
	};

	type DownloadState = {
		status: 'starting' | 'downloading' | 'completed' | 'error';
		message?: string;
		progress?: number;
		downloadedBytes?: number;
		totalSizeBytes?: number;
		remainingBytes?: number;
		speedBytesPerSec?: number;
		updatedAt?: number;
	};

	type DownloadStartResponse = {
		id?: string;
		requestId?: string;
		status?: string;
		message?: string;
		error?: string;
	};

	type DownloadStatusResponse = DownloadStartResponse & {
		progress?: number;
		progress_pct?: number;
		downloaded_bytes?: number;
		total_size_bytes?: number;
		result?: string;
		file_path?: string;
	};

	let loading = $state(true);
	let error = $state('');
	let systemData = $state<LlmfitSystem>({});
	let models = $state<LlmfitModel[]>([]);
	let totalModels = $state(0);
	let returnedModels = $state(0);
	let search = $state('');
	let minFit = $state('marginal');
	let runtime = $state('any');
	let sort = $state('score');
	let limit = $state('50');
	let downloads = $state<Record<string, DownloadState>>({});

	const API_BASE = 'http://127.0.0.1:8787/api/v1';
	const MODEL_DOWNLOAD_DIR = 'models';
	const MODEL_DOWNLOAD_RUNTIME = 'llamacpp';

	function fmt(value: number | undefined, digits = 1) {
		return typeof value === 'number' && Number.isFinite(value) ? value.toFixed(digits) : '-';
	}

	function fmtInt(value: number | undefined) {
		return typeof value === 'number' && Number.isFinite(value) ? value.toLocaleString() : '-';
	}

	function fitClass(level: string | undefined) {
		if (level === 'perfect') return 'text-emerald-400';
		if (level === 'good') return 'text-sky-400';
		if (level === 'marginal') return 'text-amber-400';
		return 'text-destructive';
	}

	function runModeClass(mode: string | undefined) {
		return mode?.toLowerCase().includes('gpu') ? 'text-emerald-400' : 'text-amber-400';
	}

	function bytesLabel(value: number | undefined) {
		if (typeof value !== 'number' || !Number.isFinite(value)) return '';
		if (value < 1024 * 1024) return `${(value / 1024).toFixed(1)} KB`;
		if (value < 1024 * 1024 * 1024) return `${(value / (1024 * 1024)).toFixed(1)} MB`;
		return `${(value / (1024 * 1024 * 1024)).toFixed(1)} GB`;
	}

	function speedLabel(value: number | undefined) {
		const label = bytesLabel(value);
		return label ? `${label}/s` : '';
	}

	function parseSizeToBytes(value: string, unit: string) {
		const size = Number.parseFloat(value);
		if (!Number.isFinite(size)) return undefined;

		const normalizedUnit = unit.toLowerCase();
		const multipliers: Record<string, number> = {
			b: 1,
			kb: 1024,
			mb: 1024 * 1024,
			gb: 1024 * 1024 * 1024,
			tb: 1024 * 1024 * 1024 * 1024
		};

		return size * (multipliers[normalizedUnit] ?? 1);
	}

	function parseDownloadMessage(message: string | undefined) {
		if (!message) return {};

		const match = message.match(/([\d.]+)\s*\/\s*([\d.]+)\s*(B|KB|MB|GB|TB)\b/i);
		if (!match) return {};

		const unit = match[3];
		return {
			downloadedBytes: parseSizeToBytes(match[1], unit),
			totalSizeBytes: parseSizeToBytes(match[2], unit)
		};
	}

	function progressPercent(state: DownloadState | undefined) {
		const raw = state?.progress;
		if (typeof raw !== 'number' || !Number.isFinite(raw)) return undefined;
		const pct = raw > 1 ? raw : raw * 100;
		return Math.max(0, Math.min(100, pct));
	}

	function remainingPercentLabel(state: DownloadState | undefined) {
		const pct = progressPercent(state);
		if (typeof pct !== 'number') return '';
		return `${Math.max(0, Math.round(100 - pct))}% left`;
	}

	function downloadLabel(state: DownloadState | undefined, canDownload = true) {
		if (!canDownload) return 'No GGUF';
		if (!state) return 'Download';
		if (state.status === 'starting') return 'Starting';
		if (state.status === 'completed') return 'Done';
		if (state.status === 'error') return 'Retry';
		const pct = progressPercent(state);
		if (typeof pct === 'number') {
			return `${Math.round(pct)}%`;
		}
		return 'Downloading';
	}

	function updateDownload(name: string, state: DownloadState) {
		const now = Date.now();
		const previous = downloads[name];
		let speedBytesPerSec = state.speedBytesPerSec;

		if (
			state.status === 'downloading' &&
			typeof state.downloadedBytes === 'number' &&
			typeof previous?.downloadedBytes === 'number' &&
			typeof previous.updatedAt === 'number'
		) {
			const elapsedSec = (now - previous.updatedAt) / 1000;
			const byteDelta = state.downloadedBytes - previous.downloadedBytes;
			if (elapsedSec > 0 && byteDelta >= 0) {
				speedBytesPerSec = byteDelta / elapsedSec;
			}
		}

		const remainingBytes =
			typeof state.downloadedBytes === 'number' && typeof state.totalSizeBytes === 'number'
				? Math.max(0, state.totalSizeBytes - state.downloadedBytes)
				: state.remainingBytes;

		downloads = {
			...downloads,
			[name]: {
				...state,
				remainingBytes,
				speedBytesPerSec,
				updatedAt: now
			}
		};
	}

	function downloadTarget(model: LlmfitModel) {
		const ggufSource = model.gguf_sources?.find((source) => source.repo)?.repo;
		if (ggufSource) return ggufSource;
		return model.name.toLowerCase().includes('gguf') ? model.name : undefined;
	}

	function downloadTitle(model: LlmfitModel, state: DownloadState | undefined) {
		if (state?.message) return state.message;
		const target = downloadTarget(model);
		if (!target) return 'No GGUF download source available for this model';
		return target === model.name
			? `Download to ${MODEL_DOWNLOAD_DIR}/`
			: `Download ${target} to ${MODEL_DOWNLOAD_DIR}/`;
	}

	function normalizeDownloadStatus(response: DownloadStatusResponse): DownloadState {
		const status = (response.status ?? response.result ?? '').toLowerCase();
		const isDone =
			status.includes('complete') ||
			status.includes('success') ||
			status.includes('finished') ||
			Boolean(response.file_path);
		const isError = status.includes('error') || status.includes('fail');
		const progress = response.progress ?? response.progress_pct;
		const message = response.error ?? response.message ?? response.file_path;
		const parsedMessage = parseDownloadMessage(message);
		const totalSizeBytes = response.total_size_bytes ?? parsedMessage.totalSizeBytes;
		const downloadedBytes =
			response.downloaded_bytes ??
			(typeof progress === 'number' && typeof totalSizeBytes === 'number'
				? totalSizeBytes * (progress > 1 ? progress / 100 : progress)
				: parsedMessage.downloadedBytes);

		return {
			status: isError ? 'error' : isDone ? 'completed' : 'downloading',
			message,
			progress,
			downloadedBytes,
			totalSizeBytes
		};
	}

	async function getJson<T>(path: string): Promise<T> {
		const response = await fetch(buildProxiedUrl(`${API_BASE}${path}`), {
			headers: buildProxiedHeaders({ Accept: 'application/json' })
		});

		if (!response.ok) {
			throw new Error(`llmfit API returned HTTP ${response.status}`);
		}

		return response.json();
	}

	async function postJson<T>(path: string, body: unknown): Promise<T> {
		const response = await fetch(buildProxiedUrl(`${API_BASE}${path}`), {
			method: 'POST',
			headers: buildProxiedHeaders({
				Accept: 'application/json',
				'Content-Type': 'application/json'
			}),
			body: JSON.stringify(body)
		});

		const text = await response.text();
		let data: Record<string, unknown> = {};
		try {
			data = text ? JSON.parse(text) : {};
		} catch {
			data = { message: text };
		}

		if (!response.ok) {
			const message = String(data.error ?? data.message ?? `llmfit API returned HTTP ${response.status}`);
			throw new Error(message);
		}

		return data as T;
	}

	async function pollDownload(modelName: string, id: string) {
		for (let attempt = 0; attempt < 180; attempt += 1) {
			await new Promise((resolve) => setTimeout(resolve, 1500));

			const status = normalizeDownloadStatus(
				await getJson<DownloadStatusResponse>(`/download/${encodeURIComponent(id)}/status`)
			);
			updateDownload(modelName, status);

			if (status.status === 'completed' || status.status === 'error') return;
		}

		updateDownload(modelName, {
			status: 'error',
			message: 'Timed out while waiting for download status'
		});
	}

	async function downloadModel(model: LlmfitModel) {
		const name = model.name;
		const target = downloadTarget(model);
		if (!target) {
			updateDownload(name, { status: 'error', message: 'No GGUF download source available for this model' });
			return;
		}

		updateDownload(name, { status: 'starting', message: `Saving ${target} to ${MODEL_DOWNLOAD_DIR}/` });

		try {
			const response = await postJson<DownloadStartResponse>('/download', {
				model: target,
				runtime: MODEL_DOWNLOAD_RUNTIME,
				download_dir: MODEL_DOWNLOAD_DIR
			});
			const id = response.id ?? response.requestId;

			updateDownload(name, {
				status: 'downloading',
				message: response.message ?? `Saving ${target} to ${MODEL_DOWNLOAD_DIR}/`
			});

			if (id) {
				await pollDownload(name, id);
			} else {
				updateDownload(name, {
					status: response.status?.toLowerCase().includes('error') ? 'error' : 'completed',
					message: response.message ?? 'Download request accepted'
				});
			}
		} catch (err) {
			updateDownload(name, {
				status: 'error',
				message: err instanceof Error ? err.message : 'Download failed'
			});
		}
	}

	async function loadData() {
		loading = true;
		error = '';

		try {
			const params = new URLSearchParams({
				limit,
				min_fit: minFit,
				sort
			});

			if (search.trim()) params.set('search', search.trim());
			if (runtime !== 'any') params.set('runtime', runtime);

			const [system, modelResponse] = await Promise.all([
				getJson<LlmfitSystem>('/system'),
				getJson<LlmfitModelsResponse>(`/models?${params}`)
			]);

			systemData = system;
			models = modelResponse.models ?? [];
			totalModels = modelResponse.total_models ?? models.length;
			returnedModels = modelResponse.returned_models ?? models.length;
		} catch (err) {
			error = err instanceof Error ? err.message : 'Unable to load llmfit data';
		} finally {
			loading = false;
		}
	}

	onMount(() => {
		void loadData();
	});
</script>

<section class="flex h-dvh min-h-0 w-full flex-col bg-background text-foreground">
	<header
		class="flex shrink-0 items-center justify-between gap-3 border-b border-border/40 py-3 pr-4 pl-16 md:px-6"
	>
		<div class="flex min-w-0 items-center gap-2">
			<Cpu class="h-5 w-5 shrink-0" />
			<h1 class="truncate text-lg font-semibold">Model Fit</h1>
		</div>

		<Button variant="outline" size="sm" onclick={loadData} disabled={loading}>
			<RefreshCw class="h-3.5 w-3.5" />
			Refresh
		</Button>
	</header>

	<div class="min-h-0 flex-1 overflow-auto p-3 md:p-5">
		{#if error}
			<div class="rounded-lg border border-destructive/30 bg-destructive/10 p-4 text-sm text-destructive">
				{error}
			</div>
		{/if}

		<div class="grid gap-4">
			<section class="rounded-lg border border-border bg-card p-4">
				<div class="mb-4 flex flex-col justify-between gap-3 md:flex-row md:items-center">
					<div>
						<p class="text-xs uppercase tracking-[0.12em] text-muted-foreground">
							{systemData.node?.name ?? 'unknown-node'} · {systemData.node?.os ?? 'local'}
						</p>
						<h2 class="mt-1 text-lg font-semibold">System Summary</h2>
					</div>
					<div class="text-sm text-muted-foreground">{systemData.system?.backend ?? 'Local'}</div>
				</div>

				<div class="grid gap-3 md:grid-cols-2 xl:grid-cols-4">
					<div class="rounded-md border border-border bg-background p-3">
						<p class="text-xs uppercase text-muted-foreground">CPU</p>
						<p class="mt-2 font-semibold">{systemData.system?.cpu_name ?? '-'}</p>
						<p class="text-sm text-muted-foreground">{systemData.system?.cpu_cores ?? '-'} cores</p>
					</div>
					<div class="rounded-md border border-border bg-background p-3">
						<p class="text-xs uppercase text-muted-foreground">Total RAM</p>
						<p class="mt-2 font-semibold">{fmt(systemData.system?.total_ram_gb)} GB</p>
					</div>
					<div class="rounded-md border border-border bg-background p-3">
						<p class="text-xs uppercase text-muted-foreground">Available RAM</p>
						<p class="mt-2 font-semibold">{fmt(systemData.system?.available_ram_gb)} GB</p>
					</div>
					<div class="rounded-md border border-border bg-background p-3">
						<p class="text-xs uppercase text-muted-foreground">GPU</p>
						<p class="mt-2 font-semibold">
							{systemData.system?.gpu_name ?? '-'} ({fmt(systemData.system?.gpu_vram_gb)} GB)
						</p>
						<p class="text-sm text-muted-foreground">
							{systemData.system?.unified_memory ? 'Unified memory' : 'Dedicated memory'}
						</p>
					</div>
				</div>
			</section>

			<section class="rounded-lg border border-border bg-card p-4">
				<div class="mb-4 flex flex-col justify-between gap-3 lg:flex-row lg:items-center">
					<div>
						<h2 class="text-lg font-semibold">Model Fit Explorer</h2>
						<p class="text-sm text-muted-foreground">
							{returnedModels} shown / {totalModels} matched
						</p>
					</div>
					<div class="grid gap-2 md:grid-cols-5">
						<label class="relative md:col-span-2">
							<Search class="pointer-events-none absolute top-2.5 left-3 h-4 w-4 text-muted-foreground" />
							<input
								class="h-9 w-full rounded-md border border-input bg-background pr-3 pl-9 text-sm outline-none focus:ring-2 focus:ring-ring"
								placeholder="Search models"
								bind:value={search}
								onkeydown={(event) => event.key === 'Enter' && loadData()}
							/>
						</label>
						<select
							class="h-9 rounded-md border border-input bg-background px-3 text-sm"
							bind:value={minFit}
							onchange={loadData}
						>
							<option value="marginal">Runnable</option>
							<option value="good">Good+</option>
							<option value="perfect">Perfect</option>
						</select>
						<select
							class="h-9 rounded-md border border-input bg-background px-3 text-sm"
							bind:value={runtime}
							onchange={loadData}
						>
							<option value="any">Any runtime</option>
							<option value="mlx">MLX</option>
							<option value="llamacpp">llama.cpp</option>
							<option value="vllm">vLLM</option>
						</select>
						<select
							class="h-9 rounded-md border border-input bg-background px-3 text-sm"
							bind:value={sort}
							onchange={loadData}
						>
							<option value="score">Score</option>
							<option value="tps">TPS</option>
							<option value="params">Params</option>
							<option value="mem">Memory</option>
							<option value="ctx">Context</option>
							<option value="date">Release</option>
						</select>
					</div>
				</div>

				<div class="overflow-auto rounded-md border border-border">
					<table class="w-full min-w-[1260px] text-sm">
						<thead class="bg-muted/50 text-xs uppercase text-muted-foreground">
							<tr>
								<th class="px-3 py-2 text-left font-medium">Model</th>
								<th class="px-3 py-2 text-left font-medium">Provider</th>
								<th class="px-3 py-2 text-left font-medium">Params</th>
								<th class="px-3 py-2 text-left font-medium">Fit</th>
								<th class="px-3 py-2 text-left font-medium">Mode</th>
								<th class="px-3 py-2 text-left font-medium">Runtime</th>
								<th class="px-3 py-2 text-right font-medium">Score</th>
								<th class="px-3 py-2 text-right font-medium">TPS</th>
								<th class="px-3 py-2 text-right font-medium">Mem%</th>
								<th class="px-3 py-2 text-right font-medium">Context</th>
								<th class="px-3 py-2 text-right font-medium">Action</th>
							</tr>
						</thead>
						<tbody>
							{#if loading}
								<tr>
									<td class="px-3 py-8 text-center text-muted-foreground" colspan="11">Loading...</td>
								</tr>
							{:else if models.length === 0}
								<tr>
									<td class="px-3 py-8 text-center text-muted-foreground" colspan="11">No models found</td>
								</tr>
							{:else}
								{#each models as model (model.name)}
									{@const state = downloads[model.name]}
									{@const pct = progressPercent(state)}
									{@const target = downloadTarget(model)}
									<tr class="border-t border-border hover:bg-muted/40">
										<td class="max-w-[26rem] truncate px-3 py-2 font-medium" title={model.name}>
											{model.name}
										</td>
										<td class="px-3 py-2 text-muted-foreground">{model.provider ?? '-'}</td>
										<td class="px-3 py-2">{model.parameter_count ?? '-'}</td>
										<td class="px-3 py-2 font-medium {fitClass(model.fit_level)}">
											{model.fit_label ?? '-'}
										</td>
										<td class="px-3 py-2 font-medium {runModeClass(model.run_mode_label)}">
											{model.run_mode_label ?? '-'}
										</td>
										<td class="px-3 py-2">{model.runtime_label ?? '-'}</td>
										<td class="px-3 py-2 text-right">{fmt(model.score)}</td>
										<td class="px-3 py-2 text-right">{fmt(model.estimated_tps)}</td>
										<td class="px-3 py-2 text-right">{fmt(model.utilization_pct)}</td>
										<td class="px-3 py-2 text-right">{fmtInt(model.context_length)}</td>
										<td class="w-[18rem] px-3 py-2 align-top">
											<div class="flex justify-end">
												<Button
													variant="outline"
													size="sm"
													class="h-8 min-w-[7.5rem] justify-center gap-1.5"
													onclick={() => target && downloadModel(model)}
													disabled={!target || state?.status === 'starting' || state?.status === 'downloading'}
													title={downloadTitle(model, state)}
												>
													{#if state?.status === 'starting' || state?.status === 'downloading'}
														<Loader2 class="h-3.5 w-3.5 animate-spin" />
													{:else if state?.status === 'completed'}
														<CheckCircle2 class="h-3.5 w-3.5 text-emerald-400" />
													{:else if state?.status === 'error' || !target}
														<XCircle class="h-3.5 w-3.5 text-destructive" />
													{:else}
														<Download class="h-3.5 w-3.5" />
													{/if}
													<span>{downloadLabel(state, Boolean(target))}</span>
												</Button>
											</div>
											{#if state?.status === 'starting'}
												<p class="mt-1 text-right text-[11px] text-muted-foreground">
													{state.message ?? 'Preparing download'}
												</p>
											{:else if state?.status === 'downloading'}
												<div class="mt-2 space-y-1">
													{#if typeof pct === 'number'}
														<div class="h-1.5 overflow-hidden rounded-full bg-muted">
															<div
																class="h-full rounded-full bg-primary transition-[width]"
																style:width={`${pct}%`}
															></div>
														</div>
													{/if}
													<p class="text-right text-[11px] leading-4 text-muted-foreground">
														{#if typeof pct === 'number'}
															{Math.round(pct)}% done · {remainingPercentLabel(state)}
															<br />
														{/if}
														{#if state.downloadedBytes}
															{bytesLabel(state.downloadedBytes)}
															{#if state.totalSizeBytes}
																/ {bytesLabel(state.totalSizeBytes)}
															{/if}
														{:else}
															Downloading
														{/if}
														{#if state.remainingBytes}
															· {bytesLabel(state.remainingBytes)} left
														{/if}
														{#if state.speedBytesPerSec}
															· {speedLabel(state.speedBytesPerSec)}
														{/if}
													</p>
													{#if state.message}
														<p class="truncate text-right text-[11px] text-muted-foreground" title={state.message}>
															{state.message}
														</p>
													{/if}
												</div>
											{:else if state?.status === 'completed'}
												<p class="mt-1 truncate text-right text-[11px] text-emerald-400" title={state.message}>
													{state.message ?? 'Saved to models/'}
												</p>
											{:else if state?.status === 'error' && state.message}
												<p class="mt-1 truncate text-right text-[11px] text-destructive" title={state.message}>
													{state.message}
												</p>
											{/if}
										</td>
									</tr>
								{/each}
							{/if}
						</tbody>
					</table>
				</div>
			</section>
		</div>
	</div>
</section>
