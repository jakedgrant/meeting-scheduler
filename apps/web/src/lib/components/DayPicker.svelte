<script lang="ts">
	import { monthCells, shiftMonth, formatDay } from '$lib/poll-flow';
	import { formatCalendarDate } from '$lib/date-time';

	let { selected, minDate, disabled = false, ontoggle }: {
		selected: string[];
		minDate: string;
		disabled?: boolean;
		ontoggle: (date: string) => void;
	} = $props();

	let month = $state(minDate.slice(0, 7));
	const cells = $derived(monthCells(month));
	const heading = $derived(formatCalendarDate(`${month}-01`, { month: 'long', year: 'numeric' }));
	const weekdays = ['Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat'];
	const sortedSelected = $derived([...selected].sort());
</script>

<div class="picker">
	<div class="head">
		<h3 id="day-picker-month" aria-live="polite">{heading}</h3>
		<div class="nav">
			<button type="button" aria-label="Previous month" disabled={month <= minDate.slice(0, 7)} onclick={() => (month = shiftMonth(month, -1))}>&lsaquo;</button>
			<button type="button" aria-label="Next month" onclick={() => (month = shiftMonth(month, 1))}>&rsaquo;</button>
		</div>
	</div>
	<div class="grid weekdays" aria-hidden="true">
		{#each weekdays as day}<span>{day}</span>{/each}
	</div>
	<div class="grid" role="group" aria-labelledby="day-picker-month">
		{#each cells as cell}
			{#if cell}
				<button
					type="button"
					class="day"
					class:picked={selected.includes(cell.date)}
					class:today={cell.date === minDate}
					aria-pressed={selected.includes(cell.date)}
					aria-label={formatCalendarDate(cell.date, { weekday: 'long', month: 'long', day: 'numeric', year: 'numeric' })}
					disabled={disabled || cell.date < minDate}
					onclick={() => ontoggle(cell.date)}
				>{cell.day}</button>
			{:else}
				<span></span>
			{/if}
		{/each}
	</div>
	<p class="count" aria-live="polite">{sortedSelected.length} {sortedSelected.length === 1 ? 'day' : 'days'} selected</p>
	{#if sortedSelected.length}
		<ul class="chips">
			{#each sortedSelected as date}<li>{formatDay(date)}</li>{/each}
		</ul>
	{/if}
</div>

<style>
	.picker { padding: 0.25rem 0 0; }
	.head { display: flex; align-items: center; justify-content: space-between; margin-bottom: 0.5rem; }
	h3 { margin: 0; font-size: 1rem; }
	.nav { display: flex; gap: 0.25rem; }
	.nav button {
		width: 44px; height: 44px; border: 0; background: transparent; font-size: 1.5rem; cursor: pointer; border-radius: 50%; color: #111;
	}
	.nav button:disabled { color: #aaa; cursor: default; }
	.grid { display: grid; grid-template-columns: repeat(7, minmax(0, 1fr)); row-gap: 4px; justify-items: center; }
	.weekdays { font-size: 0.75rem; font-weight: 600; color: #5c5c61; text-transform: uppercase; margin-bottom: 4px; }
	.day {
		width: 100%; max-width: 44px; aspect-ratio: 1; min-height: 40px; border: 0; border-radius: 50%; background: transparent;
		font: inherit; font-size: 1rem; color: #111; cursor: pointer;
	}
	.day:hover:not(:disabled) { background: #eef3fb; }
	.day:disabled { color: #aaa; cursor: default; }
	.day.today { background: #e6f0fd; color: #0b4a9e; }
	.day.picked { background: #0b63ce; color: #fff; }
	.day:focus-visible, .nav button:focus-visible { outline: 3px solid #0b63ce; outline-offset: 2px; }
	.count { margin: 0.75rem 0 0.5rem; font-size: 0.8125rem; color: #5c5c61; }
	.chips { list-style: none; padding: 0; margin: 0; display: flex; flex-wrap: wrap; gap: 0.5rem; }
	.chips li { background: #e6f0fd; color: #0b4a9e; border-radius: 14px; padding: 0.25rem 0.75rem; font-size: 0.875rem; font-weight: 600; }
</style>
