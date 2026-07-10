const views = Object.fromEntries(['loading','select','install','success'].map(id => [id, document.getElementById(id)]));
let data, selected, timer, activeCard;
const show = name => Object.entries(views).forEach(([key,node]) => node.classList.toggle('active', key === name));
const gb = n => `${Number(n || 0).toFixed(Number(n || 0) < 10 ? 1 : 0)} GB`;
const bytes = n => !n ? 'Calculating size…' : n >= 1073741824 ? `${(n/1073741824).toFixed(1)} GB` : `${(n/1048576).toFixed(0)} MB`;

async function api(url, options={}) {
  const response = await fetch(url, options); const body = await response.json().catch(() => ({}));
  if (!response.ok) throw new Error(body.error || `Request failed (${response.status})`); return body;
}

function item(label, value, cls='') {
  const node=document.createElement('div'); node.className=cls;
  const small=document.createElement('span'); small.textContent=label;
  const strong=document.createElement('strong'); strong.textContent=value;
  node.append(small,strong); return node;
}

function renderSystem(s) {
  document.getElementById('specs').replaceChildren(
    item('Processor',`${s.cpu_name} · ${s.cpu_cores} cores`), item('Total RAM',gb(s.total_ram_gb)), item('Available now',gb(s.available_ram_gb)),
    item('Graphics',s.has_gpu ? `${s.gpu_name} · ${gb(s.gpu_vram_gb)}` : 'CPU inference'), item('Acceleration',String(s.backend).toUpperCase())
  );
}

function findPartialMatch(model, list) {
  if (!list) return false;
  const mName = model.name.split('/').pop().toLowerCase().replace(/[-_]/g, '');
  const mQuant = model.quant.toLowerCase().replace(/[-_]/g, '');
  return list.some(p => {
    const pClean = p.toLowerCase().replace(/[-_]/g, '');
    return pClean.includes(mName) && pClean.includes(mQuant);
  });
}

function renderModels(models, searchMode=false) {
  const root=document.getElementById('models'); root.replaceChildren();
  if(!models.length){const empty=document.createElement('div');empty.className='empty';empty.textContent='No downloadable models matched this search. Try a broader model family name.';root.append(empty);return;}
  models.forEach((m,index) => {
    const hasComplete = data.installed_models && findPartialMatch(m, data.installed_models);
    const hasPartial = data.partial_models && findPartialMatch(m, data.partial_models);
    const highlighted=!searchMode&&index===0; const card=document.createElement('article'); card.className=`card${highlighted?' best':''}`;
    const top=document.createElement('div'); top.className='card-top';
    const title=document.createElement('div'); const badge=document.createElement('span'); badge.className='badge'; badge.textContent=highlighted?'Best fit':m.fit_level;
    const h=document.createElement('h2'); h.textContent=m.name.split('/').pop(); const repo=document.createElement('p'); repo.textContent=m.repo; title.append(badge,h,repo);
    const score=document.createElement('div'); score.className='score'; const scoreLabel=document.createElement('span');scoreLabel.textContent='Fit score';const scoreValue=document.createElement('b');scoreValue.textContent=`${Math.round(m.score)}/100`;score.append(scoreLabel,scoreValue);
    const parts=m.score_components||{};score.title=`Quality ${Math.round(parts.quality||0)} · Speed ${Math.round(parts.speed||0)} · Memory fit ${Math.round(parts.fit||0)} · Context ${Math.round(parts.context||0)}`;top.append(title,score);
    const metrics=document.createElement('div'); metrics.className='metrics'; metrics.append(item('Quant',m.quant),item('Download',gb(m.disk_size_gb)),item('Memory',gb(m.memory_required_gb)),item('Speed',`~${Math.round(m.speed_tps)} tok/s`),item('Context',`${Math.round(m.context/1024)}K`),item('Mode',m.run_mode));
    const button=document.createElement('button');
    let browserLink = null;
    if (hasComplete) {
      button.className = 'button primary';
      button.textContent = 'Use installed model';
    } else {
      if (hasPartial) {
        button.className = 'button primary';
        button.textContent = 'Continue download';
      } else {
        button.className=`button ${highlighted?'primary':'subtle'}`;
        button.textContent='Download Now';
      }
      button.onclick=()=>start(m);
      browserLink = document.createElement('div');
      browserLink.className = 'browser-download-container';
      browserLink.innerHTML = `<a href="#" class="browser-dl-link">Download in browser</a><small class="browser-dl-help hidden">Note: Save the downloaded file into the <code>models/</code> folder of this project.</small>`;
      browserLink.querySelector('.browser-dl-link').onclick = (e) => {
        e.preventDefault();
        triggerBrowserDownload(m.id, e.target);
      };
    }
    const inline=document.createElement('div');inline.className='inline-download hidden';inline.innerHTML='<div class="progress-row"><span class="inline-file">Preparing model files…</span><strong class="inline-percent">Working</strong></div><div class="track"><div class="bar inline-bar"></div></div><div class="stats"><span class="inline-size">Preparing files…</span><span class="inline-speed"></span><span class="inline-remaining"></span></div><p class="inline-message"></p><div class="download-actions"><button class="button cancel">Cancel download</button><a class="button subtle browser-download hidden" target="_blank">Download in browser</a></div><small class="browser-download-note hidden">Note: Save the downloaded file into the <code>models/</code> folder of this project.</small>';
    inline.querySelector('.cancel').onclick=cancelDownload;card.dataset.recommendationId=m.id;
    if (browserLink) {
      card.append(top,metrics,button,browserLink,inline);
    } else {
      card.append(top,metrics,button,inline);
    }
    root.append(card);
  });
}

async function triggerBrowserDownload(id, element) {
  if (element.classList.contains('resolving')) return;
  const originalText = element.textContent;
  element.textContent = 'Resolving link…';
  element.classList.add('resolving');
  try {
    const res = await api(`/api/resolve-url?id=${id}`);
    element.textContent = originalText;
    element.classList.remove('resolving');
    const a = document.createElement('a');
    a.href = res.url;
    a.target = '_blank';
    a.download = res.filename;
    document.body.appendChild(a);
    a.click();
    document.body.removeChild(a);
    const container = element.closest('.browser-download-container');
    if (container) {
      const help = container.querySelector('.browser-dl-help');
      if (help) help.classList.remove('hidden');
    }
  } catch (e) {
    element.textContent = 'Error resolving link';
    element.classList.remove('resolving');
    setTimeout(() => { element.textContent = originalText; }, 3000);
  }
}

async function boot() {
  try { data=await api('/api/bootstrap'); renderSystem(data.system); renderModels(data.recommendations); document.getElementById('source').textContent='Powered by llmfit'; show('select'); }
  catch(e) { document.querySelector('#loading h1').textContent='Model setup could not start'; document.querySelector('#loading p').textContent=e.message; document.querySelector('.spinner').classList.add('failed'); }
}

async function searchModels(){
  const input=document.getElementById('search-input');const query=input.value.trim();if(query.length<2){document.getElementById('search-status').textContent='Enter at least 2 characters to search.';input.focus();return;}
  const button=document.getElementById('search-button');button.disabled=true;button.textContent='Searching…';document.getElementById('search-status').textContent=`Finding ${query} models that fit this computer…`;
  try{const result=await api(`/api/search?q=${encodeURIComponent(query)}`);renderModels(result.results,true);document.getElementById('search-status').textContent=result.results.length?`${result.results.length} compatible ${query} model${result.results.length===1?'':'s'} found. Results are ranked by fit score.`:`No downloadable ${query} models matched.`;document.getElementById('clear-search').classList.remove('hidden');}
  catch(e){document.getElementById('search-status').textContent=e.message;}
  finally{button.disabled=false;button.textContent='Search models';}
}

async function start(model) {
  selected=model; activeCard=document.querySelector(`.card[data-recommendation-id="${model.id}"]`);if(!activeCard)return;
  document.querySelectorAll('.card > .button').forEach(button=>button.disabled=true);document.getElementById('search-button').disabled=true;document.getElementById('search-input').disabled=true;document.getElementById('clear-search').disabled=true;
  activeCard.classList.add('downloading');const inline=activeCard.querySelector('.inline-download');inline.classList.remove('hidden');activeCard.querySelector(':scope > .button').classList.add('hidden');
  const bLink = activeCard.querySelector('.browser-download-container');
  if (bLink) bLink.classList.add('hidden');
  const action=inline.querySelector('.cancel');action.disabled=false;action.textContent='Cancel download';action.classList.remove('resume');action.onclick=cancelDownload;inline.querySelector('.inline-message').textContent='Checking free space…';inline.querySelector('.inline-message').classList.remove('failure');
  inline.querySelector('.browser-download').classList.add('hidden');
  inline.querySelector('.browser-download-note').classList.add('hidden');
  try { await api('/api/download',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({recommendation_id:model.id})}); clearInterval(timer); timer=setInterval(poll,500); poll(); }
  catch(e) { inlineFailure(e.message); }
}

async function poll() {
  try {
    const s=await api('/api/status');
    if(!activeCard)return;const inline=activeCard.querySelector('.inline-download');
    inline.querySelector('.inline-file').textContent=s.filename||({preflight:'Checking storage',metadata:'Finding GGUF files',canceling:'Canceling'})[s.stage]||'Preparing';
    inline.querySelector('.inline-percent').textContent=s.total_bytes?`${Math.round(s.percent)}%`:'Working';const inlineBar=inline.querySelector('.inline-bar');inlineBar.style.width=s.total_bytes?`${s.percent}%`:'35%';inlineBar.classList.toggle('indeterminate',!s.total_bytes);
    inline.querySelector('.inline-size').textContent=s.total_bytes?`${bytes(s.downloaded_bytes)} of ${bytes(s.total_bytes)}`:'Preparing files…';inline.querySelector('.inline-speed').textContent=s.speed_mb?`${Number(s.speed_mb).toFixed(1)} MB/s`:'';inline.querySelector('.inline-remaining').textContent=s.remaining_bytes?`${bytes(s.remaining_bytes)} left`:'';inline.querySelector('.inline-message').textContent=s.message||'';
    if(s.download_url){
      const dlLink = inline.querySelector('.browser-download');
      dlLink.href = s.download_url;
      dlLink.classList.remove('hidden');
      inline.querySelector('.browser-download-note').classList.remove('hidden');
    }
    document.getElementById('stage').textContent=({preflight:'Preflight',metadata:'Model files',download:'Downloading',complete:'Complete'})[s.stage]||'Preparing';
    document.getElementById('message').textContent=s.message; document.getElementById('filename').textContent=s.filename||'Preparing';
    document.getElementById('percent').textContent=s.total_bytes?`${Math.round(s.percent)}%`:'Working';
    const bar=document.getElementById('bar'); bar.style.width=s.total_bytes?`${s.percent}%`:'35%'; bar.classList.toggle('indeterminate',!s.total_bytes);
    document.getElementById('size').textContent=s.total_bytes?`${bytes(s.downloaded_bytes)} of ${bytes(s.total_bytes)}`:'Preparing files…';
    document.getElementById('speed').textContent=s.speed_mb?`${Number(s.speed_mb).toFixed(1)} MB/s`:''; document.getElementById('remaining').textContent=s.remaining_bytes?`${bytes(s.remaining_bytes)} left`:'';
    if(s.error){clearInterval(timer);inlineFailure(s.error);}else if(s.stage==='canceled'){clearInterval(timer);inlineFailure('Download canceled. Your partial download is saved.',true);}else if(s.complete){clearInterval(timer);activeCard.classList.remove('downloading');activeCard.classList.add('download-complete');document.getElementById('chosen').textContent=`${selected.name.split('/').pop()} · ${selected.quant}`;show('success');}
  } catch(e){clearInterval(timer);inlineFailure(e.message);}
}

function fail(message){document.getElementById('progress').classList.add('hidden');document.getElementById('error-text').textContent=message;document.getElementById('error').classList.remove('hidden');}
function enableModelControls(){document.querySelectorAll('.card > .button').forEach(button=>button.disabled=false);document.getElementById('search-button').disabled=false;document.getElementById('search-input').disabled=false;document.getElementById('clear-search').disabled=false;}
function inlineFailure(message,canceled=false){if(!activeCard)return;activeCard.classList.remove('downloading');const inline=activeCard.querySelector('.inline-download');const text=inline.querySelector('.inline-message');text.textContent=message;text.classList.add('failure');const action=inline.querySelector('.cancel');action.disabled=false;action.textContent=canceled?'Resume download':'Try download again';action.classList.add('resume');action.onclick=()=>start(selected);const bLink=activeCard.querySelector('.browser-download-container');if(bLink)bLink.classList.remove('hidden');enableModelControls();}
async function cancelDownload(){if(!activeCard)return;const button=activeCard.querySelector('.cancel');button.disabled=true;button.textContent='Canceling…';try{await api('/api/cancel',{method:'POST'});}catch(e){button.disabled=false;button.textContent='Cancel download';activeCard.querySelector('.inline-message').textContent=e.message;}}
document.getElementById('retry').onclick=()=>start(selected); document.getElementById('back').onclick=()=>show('select');
document.getElementById('search-button').onclick=searchModels;document.getElementById('search-input').addEventListener('keydown',event=>{if(event.key==='Enter')searchModels();});document.getElementById('clear-search').onclick=()=>{document.getElementById('search-input').value='';renderModels(data.recommendations);document.getElementById('search-status').textContent='Search llmfit’s catalog and download any compatible GGUF model.';document.getElementById('clear-search').classList.add('hidden');};
document.getElementById('finish').onclick=async e=>{const b=e.currentTarget;b.disabled=true;b.textContent='Starting…';try{await api('/api/finish',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({prompt:document.getElementById('first-prompt').value})});document.querySelector('#success h1').textContent='Opening the Web UI';document.querySelector('#success p:not(.eyebrow)').textContent='Return to the launcher window while the server starts.';b.classList.add('hidden');document.querySelector('.first-prompt').classList.add('hidden');}catch(err){b.disabled=false;b.textContent='Try again';}};
boot();
