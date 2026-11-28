<script lang="ts">
	import type { AvailabilityStatus, PollTimeOption } from '$lib/supabase';
	import { answerLabels, optionDateLabel, tallySegments, timeRangeLabel } from '$lib/time-option-labels';
	import { currentZone } from '$lib/date-time';

	/** What the viewer's calendar says about this option. */
	type CalendarStatus = 'free' | 'busy' | 'unchecked';

	let {
		option,
		pollZone,
		now,
		calendarStatus,
		stats,
		showTallies,
		canRespond,
		disabled,
		response,
		onrespond,
		onshowresponses
	}: {
		option: PollTimeOption;
		pollZone: string;
		now: Date;
		calendarStatus: CalendarStatus;
		stats: Record<AvailabilityStatus, number>;
		showTallies: boolean;
		canRespond: boolean;
		disabled: boolean;
		response: AvailabilityStatus | undefined;
		onrespond: (status: AvailabilityStatus) => void;
		onshowresponses: () => void;
	} = $props();

	const statuses: AvailabilityStatus[] = ['available', 'maybe', 'unavailable'];
	const viewerZone = currentZone();
	const dateLabel = $derived(optionDateLabel(option, pollZone, now, viewerZone));
	const timeLabel = $derived(option.is_all_day ? 'All day' : timeRangeLabel(option.start_time, option.end_time, viewerZone));
	const segments = $derived(tallySegments(stats));
	const conflictText = 'Conflicts with an event on your Google Calendar';
	let conflictDialog: HTMLDialogElement | undefined = $state();
</script>

<div class="row">
	<div class="main-line">
		<button class="when" onclick={onshowresponses} title="View everyone's responses">
			<span class="date">{dateLabel}</span>
			<span class="time">{timeLabel}</span>
		</button>

		{#if canRespond}
			<div class="response-control" role="group" aria-label={`Your response: ${response ? answerLabels[response] : 'No response'}`}>
				{#each statuses as status}
					{@const selected = response === status}
					<button
						class="response {status}"
						class:selected
						aria-label={answerLabels[status]}
						aria-pressed={selected}
						{disabled}
						onclick={() => { if (!selected) onrespond(status); }}
					>
						<svg viewBox="0 0 24 24" aria-hidden="true">
							{#if status === 'available'}
								<path d="M5 12.5l4.5 4.5L19 7.5" />
							{:else if status === 'maybe'}
								<circle cx="12" cy="12" r="9" />
								<path d="M9.5 9.5a2.5 2.5 0 1 1 3.5 2.3c-.6.3-1 .8-1 1.5v.7" />
								<circle class="dot" cx="12" cy="17" r="0.6" />
							{:else}
								<path d="M6.5 6.5l11 11M17.5 6.5l-11 11" />
							{/if}
						</svg>
					</button>
				{/each}
			</div>
		{/if}
	</div>

	{#if calendarStatus === 'busy'}
		<button
			class="conflict"
			onclick={() => conflictDialog?.showModal()}
			aria-label="Conflict: an event on your Google Calendar"
			title="Show conflict details"
		>
			<svg viewBox="0 0 24 24" aria-hidden="true">
				<rect x="4" y="5.5" width="16" height="14.5" rx="2" />
				<path d="M4 10h16M8.5 3.5v4M15.5 3.5v4M12 13v3M12 18.2v.1" />
			</svg>
			<span class="conflict-text">{conflictText}</span>
			<svg class="chevron" viewBox="0 0 24 24" aria-hidden="true"><path d="M9.5 6l6 6-6 6" /></svg>
		</button>
		<dialog bind:this={conflictDialog} aria-labelledby={`conflict-title-${option.id}`}>
			<h3 id={`conflict-title-${option.id}`}>Calendar conflict</h3>
			<p class="proposed">{dateLabel}, {timeLabel}</p>
			<p>Google Calendar says you're busy during this time. It doesn't share which event.</p>
			<form method="dialog"><button class="btn secondary">Done</button></form>
		</dialog>
	{:else if calendarStatus === 'unchecked'}
		<p class="unchecked">Couldn't check</p>
	{/if}

	{#if showTallies}
		<div class="tally" role="img" aria-label={`${stats.available} yes, ${stats.maybe} maybe, ${stats.unavailable} no`}>
			{#each segments as segment (segment.status)}
				<span class="segment {segment.status}" style:flex-grow={segment.count}></span>
			{:else}
				<span class="segment empty"></span>
			{/each}
		</div>
	{/if}
</div>

<style>
	.row {
		container-type: inline-size;
		display: flex;
		flex-direction: column;
		gap: 10px;
		padding: 14px 0;
	}

	.main-line {
		display: flex;
		align-items: center;
		gap: 10px;
	}

	.when {
		flex: 1 1 10rem;
		display: flex;
		flex-direction: column;
		min-width: 0;
		padding: 0;
		border: none;
		background: none;
		color: inherit;
		font: inherit;
		text-align: left;
		cursor: pointer;
	}

	.when span {
		white-space: nowrap;
		overflow: hidden;
		text-overflow: ellipsis;
	}

	.date {
		font-size: 1.0625rem;
		font-weight: 600;
	}

	.time {
		font-size: 0.9375rem;
		color: #6c6c70;
	}

	.response-control {
		display: flex;
		gap: 6px;
	}

	.response {
		display: inline-flex;
		align-items: center;
		justify-content: center;
		min-width: 44px;
		height: 36px;
		padding: 0;
		border: 0.5px solid #c6c6c8;
		border-radius: 8px;
		background: transparent;
		color: #6c6c70;
		cursor: pointer;
	}

	.response:disabled {
		cursor: default;
		opacity: 0.6;
	}

	.response svg {
		width: 16px;
		height: 16px;
		fill: none;
		stroke: currentColor;
		stroke-width: 2;
		stroke-linecap: round;
		stroke-linejoin: round;
	}

	.response svg .dot {
		fill: currentColor;
	}

	.response.selected {
		border-color: transparent;
	}

	.response.selected svg {
		width: 18px;
		height: 18px;
	}

	/*
	 * When large text (or a narrow screen) leaves no room beside the date, the answer buttons move
	 * under it, grow with the text size and share the row's width.
	 */
	@container (max-width: 20rem) {
		.main-line {
			flex-direction: column;
			align-items: stretch;
		}

		.when {
			flex: none;
		}

		.when span {
			white-space: normal;
		}

		.response {
			flex: 1;
			height: 2.25rem;
		}

		.response svg {
			width: 1rem;
			height: 1rem;
		}

		.response.selected svg {
			width: 1.125rem;
			height: 1.125rem;
		}
	}

	.response.available.selected {
		background: rgb(52 199 89 / 0.15);
		color: #248a3d;
	}

	.response.maybe.selected {
		background: rgb(255 149 0 / 0.15);
		color: #c93400;
	}

	.response.unavailable.selected {
		background: rgb(255 59 48 / 0.15);
		color: #d70015;
	}

	.conflict {
		display: flex;
		align-items: center;
		gap: 6px;
		width: 100%;
		padding: 8px 10px;
		border: none;
		border-radius: 8px;
		background: rgb(255 149 0 / 0.15);
		color: #c93400;
		font: inherit;
		font-size: 0.8125rem;
		text-align: left;
		cursor: pointer;
	}

	.conflict svg {
		flex: none;
		width: 16px;
		height: 16px;
		fill: none;
		stroke: currentColor;
		stroke-width: 1.8;
		stroke-linecap: round;
	}

	.conflict .chevron {
		width: 14px;
		height: 14px;
	}

	.conflict-text {
		flex: 1;
		display: -webkit-box;
		-webkit-line-clamp: 2;
		line-clamp: 2;
		-webkit-box-orient: vertical;
		overflow: hidden;
	}

	.unchecked {
		margin: 0;
		font-size: 0.8125rem;
		color: #6c6c70;
	}

	.tally {
		display: flex;
		gap: 2px;
		height: 4px;
	}

	.segment {
		flex: 1 1 0;
		border-radius: 2px;
	}

	.segment.available {
		background: #34c759;
	}

	.segment.maybe {
		background: #ff9500;
	}

	.segment.unavailable {
		background: #ff3b30;
	}

	.segment.empty {
		background: #c6c6c8;
	}

	dialog {
		max-width: min(24rem, calc(100vw - 2rem));
		border: none;
		border-radius: 12px;
		padding: 1.25rem;
	}

	dialog h3 {
		margin: 0 0 0.25rem;
	}

	dialog .proposed {
		margin-top: 0;
		color: #6c6c70;
	}

	dialog form {
		display: flex;
		justify-content: flex-end;
	}
</style>
