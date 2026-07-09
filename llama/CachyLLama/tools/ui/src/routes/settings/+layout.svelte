<script lang="ts">
	import { X } from '@lucide/svelte';
	import { goto } from '$app/navigation';
	import { browser } from '$app/environment';
	import { page } from '$app/state';
	import { ActionIcon } from '$lib/components/app';
	import { SETTINGS_FALLBACK_EXIT_ROUTE, SETTINGS_SECTION_SLUGS } from '$lib/constants';

	let { children } = $props();

	let previousRouteId = $state<string | null>(null);

	$effect(() => {
		const currentId = page.route.id;
		return () => {
			previousRouteId = currentId;
		};
	});

	function handleClose() {
		const prevIsSettings = previousRouteId?.startsWith('/settings');
		if (browser && window.history.length > 1 && !prevIsSettings) {
			history.back();
		} else {
			goto(SETTINGS_FALLBACK_EXIT_ROUTE);
		}
	}

	let isModelFit = $derived(
		(page.params as Record<string, string | undefined>).section === SETTINGS_SECTION_SLUGS.FIT
	);
</script>

{#if !isModelFit}
	<div class="fixed top-4.5 right-4 z-50 md:hidden">
		<ActionIcon icon={X} tooltip="Close" onclick={handleClose} />
	</div>
{/if}

<div class="min-h-full">
	{@render children?.()}
</div>
