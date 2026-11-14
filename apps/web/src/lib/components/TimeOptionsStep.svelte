<script lang="ts">
	import DayPicker from '$lib/components/DayPicker.svelte';
	import { dateRange } from '$lib/date-time';
	import { formatDay } from '$lib/poll-flow';
	import type { CreationDraft } from '$lib/poll-creation';

	type Option = CreationDraft['timeOptions'][number];

	let { isAllDay, timeOptions, today, locked, onedit, onerror }: {
		isAllDay: boolean;
		timeOptions: Option[];
		today: string;
		locked: boolean;
		onedit: (update: Partial<CreationDraft>) => void;
		onerror: (message: string) => void;
	} = $props();

	let rangeOpen = $state(false);
	let rangeStartDate = $state(today);
	let rangeEndDate = $state(today);
	let rangeStartTime = $state('09:00');
	let rangeEndTime = $state('10:00');

	const times = Array.from({ length: 96 }, (_, i) => `${String(Math.floor(i / 4)).padStart(2, '0')}:${String((i % 4) * 15).padStart(2, '0')}`);
	const minutes = (time: string) => { const [h, m] = time.split(':').map(Number); return h * 60 + m; };
	const invalidRange = (start: string, end: string) => minutes(end) <= minutes(start);
	const endTimes = (start: string) => times.filter(time => !invalidRange(start, time));
	const label = (time: string) => new Date(`2000-01-01T${time}:00`).toLocaleTimeString('en-US', { hour: 'numeric', minute: '2-digit' });
	const sorted = (options: Option[]) => [...options].sort((a, b) => `${a.date}T${a.startTime}`.localeCompare(`${b.date}T${b.startTime}`));
	const nextStart = (time: string) => times.find(candidate => minutes(candidate) > minutes(time)) ?? time;

	function addOption() {
		onedit({ timeOptions: [...timeOptions, { id: crypto.randomUUID(), date: today, startTime: '09:00', endTime: '10:00' }] });
	}

	function removeOption(id: string) {
		onedit({ timeOptions: timeOptions.filter(option => option.id !== id) });
	}

	function update(id: string, field: keyof Option, value: string) {
		onedit({ timeOptions: timeOptions.map(option => {
			if (option.id !== id) return option;
			const next = { ...option, [field]: value };
			if (field === 'startTime' && invalidRange(value, next.endTime)) next.endTime = nextStart(value);
			return next;
		}) });
	}

	function addRange() {
		if (!rangeStartDate || !rangeEndDate) return onerror('Please select both start and end dates for the range');
		if (rangeStartDate > rangeEndDate) return onerror('Start date must be before or equal to end date');
		if (!isAllDay && invalidRange(rangeStartTime, rangeEndTime)) return onerror('End time must be after start time');
		// One option per calendar date. Date-only arithmetic keeps clock changes from skipping a date.
		const added = dateRange(rangeStartDate, rangeEndDate).map(date => ({ id: crypto.randomUUID(), date, startTime: rangeStartTime, endTime: rangeEndTime }));
		onedit({ timeOptions: sorted([...timeOptions, ...added]) });
		rangeStartDate = today; rangeEndDate = today; rangeStartTime = '09:00'; rangeEndTime = '10:00';
		rangeOpen = false;
	}

	function toggleDay(date: string) {
		const picked = timeOptions.some(option => option.date === date);
		onedit({ timeOptions: picked
			? timeOptions.filter(option => option.date !== date)
			: sorted([...timeOptions, { id: crypto.randomUUID(), date, startTime: '09:00', endTime: '10:00' }]) });
	}

	function setAllDay(value: boolean) {
		// Days are unique when all-day: keep one option per date.
		const seen = new Set<string>();
		const options = value ? timeOptions.filter(option => !seen.has(option.date) && seen.add(option.date)) : timeOptions;
		onedit({ isAllDay: value, timeOptions: options });
	}
</script>

<div class="card">
	<div class="row">
		<label for="all-day">All-day events</label>
		<button id="all-day" type="button" role="switch" aria-checked={isAllDay} class="switch" class:on={isAllDay} disabled={locked} onclick={() => setAllDay(!isAllDay)}><span></span></button>
	</div>
	{#if !isAllDay}
		<button type="button" class="disclosure" aria-expanded={rangeOpen} aria-controls="range-panel" onclick={() => (rangeOpen = !rangeOpen)}>
			<span>Add Date Range</span>
			<span class="chevron" class:open={rangeOpen} aria-hidden="true">&rsaquo;</span>
		</button>
		{#if rangeOpen}
			<div id="range-panel" class="range">
				<div class="pair">
					<div class="field">
						<label for="range-start-date">Start date</label>
						<input id="range-start-date" type="date" min={today} bind:value={rangeStartDate} disabled={locked} />
					</div>
					<div class="field">
						<label for="range-end-date">End date</label>
						<input id="range-end-date" type="date" min={rangeStartDate || today} bind:value={rangeEndDate} disabled={locked} />
					</div>
				</div>
				<div class="pair">
					<div class="field">
						<label for="range-start-time">Start time</label>
						<select id="range-start-time" bind:value={rangeStartTime} disabled={locked}>
							{#each times as time}<option value={time}>{label(time)}</option>{/each}
						</select>
					</div>
					<div class="field">
						<label for="range-end-time">End time</label>
						<select id="range-end-time" bind:value={rangeEndTime} disabled={locked}>
							{#each endTimes(rangeStartTime) as time}<option value={time}>{label(time)}</option>{/each}
						</select>
					</div>
				</div>
				<button type="button" class="pill primary" onclick={addRange} disabled={locked}>Add days to poll</button>
			</div>
		{/if}
	{/if}
</div>

{#if isAllDay}
	<div class="card pad">
		<DayPicker selected={timeOptions.map(option => option.date)} minDate={today} disabled={locked} ontoggle={toggleDay} />
	</div>
{:else}
	<p class="count" aria-live="polite">{timeOptions.length} {timeOptions.length === 1 ? 'option' : 'options'}</p>
	<div class="card">
		<ul class="options">
			{#each timeOptions as option, index (option.id)}
				<li class="time-option">
					<div class="option-head">
						<h3>Option {index + 1}</h3>
						<button type="button" class="icon-text" aria-label={`Remove option ${index + 1}`} disabled={locked} onclick={() => removeOption(option.id)}>Remove</button>
					</div>
					<div class="when">
						<span class="when-label" id={`starts-${option.id}`}>Starts</span>
						<input type="date" aria-labelledby={`starts-${option.id}`} min={today} value={option.date} required onchange={(e) => update(option.id, 'date', e.currentTarget.value)} disabled={locked} />
						<select aria-label={`Option ${index + 1} start time`} value={option.startTime} onchange={(e) => update(option.id, 'startTime', e.currentTarget.value)} disabled={locked}>
							{#each times as time}<option value={time}>{label(time)}</option>{/each}
						</select>
					</div>
					<div class="when">
						<span class="when-label" id={`ends-${option.id}`}>Ends</span>
						<span class="same-day" aria-labelledby={`ends-${option.id}`}>{option.date ? formatDay(option.date) : 'Same day'}</span>
						<select aria-label={`Option ${index + 1} end time`} value={option.endTime} onchange={(e) => update(option.id, 'endTime', e.currentTarget.value)} disabled={locked}>
							{#each endTimes(option.startTime) as time}<option value={time}>{label(time)}</option>{/each}
						</select>
					</div>
				</li>
			{/each}
		</ul>
		<button type="button" class="add" onclick={addOption} disabled={locked}>
			<span aria-hidden="true">+</span> Add Time Option
		</button>
	</div>
{/if}

<style>
	.card { background: #fff; border-radius: 16px; overflow: hidden; box-shadow: 0 1px 3px rgba(0, 0, 0, 0.1); margin-bottom: 0.75rem; }
	.card.pad { padding: 0.75rem 1rem 1rem; }
	.row, .disclosure { display: flex; align-items: center; justify-content: space-between; min-height: 56px; padding: 0 1.25rem; box-sizing: border-box; width: 100%; }
	.row label { font-size: 1.0625rem; }
	.disclosure { border: 0; border-top: 1px solid #e5e5ea; background: transparent; font: inherit; font-size: 1.0625rem; font-weight: 600; cursor: pointer; text-align: left; }
	.chevron { font-size: 1.5rem; transition: transform 0.15s; }
	.chevron.open { transform: rotate(90deg); }
	.switch { width: 51px; height: 31px; border-radius: 16px; border: 0; padding: 2px; background: #8e8e93; display: flex; align-items: center; cursor: pointer; }
	.switch span { width: 27px; height: 27px; border-radius: 50%; background: #fff; box-shadow: 0 1px 3px rgba(0, 0, 0, 0.3); transition: transform 0.15s; }
	.switch.on { background: #1f7a3d; }
	.switch.on span { transform: translateX(20px); }
	.switch:focus-visible, .disclosure:focus-visible, .add:focus-visible, .pill:focus-visible, .icon-text:focus-visible { outline: 3px solid #0b63ce; outline-offset: -3px; }
	.range { padding: 0.5rem 1.25rem 1.25rem; display: flex; flex-direction: column; gap: 0.75rem; }
	.pair { display: grid; grid-template-columns: repeat(auto-fit, minmax(140px, 1fr)); gap: 0.75rem; }
	.field { display: flex; flex-direction: column; gap: 0.25rem; }
	.field label { font-size: 0.8125rem; color: #5c5c61; margin: 0; font-weight: 400; }
	input[type='date'], select { font: inherit; font-size: 1rem; padding: 0.5rem 0.625rem; border: 1px solid #d1d1d6; border-radius: 10px; background: #f7f7fa; min-height: 44px; box-sizing: border-box; color: #111; }
	input:focus-visible, select:focus-visible { outline: 3px solid #0b63ce; outline-offset: 1px; }
	.pill { min-height: 48px; border: 0; border-radius: 24px; font: inherit; font-weight: 600; cursor: pointer; padding: 0 1.25rem; }
	.pill.primary { background: #0b63ce; color: #fff; }
	.pill:disabled { opacity: 0.5; }
	.count { margin: 0.5rem 1.25rem 0.5rem; font-size: 0.8125rem; color: #5c5c61; }
	.options { list-style: none; margin: 0; padding: 0; }
	.time-option { padding: 0.875rem 1rem 1rem; border-bottom: 1px solid #e5e5ea; display: flex; flex-direction: column; gap: 0.625rem; }
	.option-head { display: flex; align-items: center; justify-content: space-between; }
	h3 { margin: 0; font-size: 1.0625rem; }
	.icon-text { min-height: 44px; padding: 0 0.75rem; margin: -0.5rem -0.5rem -0.5rem 0; border: 0; background: transparent; color: #a3261d; font: inherit; font-size: 0.9375rem; cursor: pointer; }
	.when { display: flex; align-items: center; gap: 0.5rem; flex-wrap: wrap; }
	.when-label { width: 3.25rem; font-size: 0.9375rem; color: #5c5c61; }
	.same-day { padding: 0.5rem 0.625rem; font-size: 1rem; }
	.add { display: flex; align-items: center; gap: 0.75rem; width: 100%; min-height: 56px; padding: 0 1rem; border: 0; background: transparent; font: inherit; font-size: 1.0625rem; color: #0b63ce; cursor: pointer; text-align: left; }
	.add:disabled { opacity: 0.5; }
</style>
