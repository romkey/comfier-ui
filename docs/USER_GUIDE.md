# Comfier user guide

Comfier lets you make images, video, audio and 3D models by describing what you want. The heavy lifting happens on
ComfyUI servers your admins have set up; you never need to touch a node graph.

- [Signing in](#signing-in)
- [Making things](#making-things)
- [Results](#results)
- [Shared](#shared)
- [Queue](#queue)
- [Chat](#chat)
- [Settings](#settings)
- [Servers](#servers)
- [For admins: backends](#for-admins-backends)
- [For admins: workflows](#for-admins-workflows)
- [How-to](#how-to)

## Signing in

Open Comfier and choose **Sign in with Authentik**. You'll go to your organization's Authentik login and come straight back. Your
account is created the first time you sign in. If you're in the admin group in Authentik, you'll see the admin
sections of Settings too.

The first time you sign in (or after an admin updates the notice and asks everyone to agree again), you'll see a short
**Code of Conduct and privacy** page. It sums up the PDX Hackerspace Code of Conduct, with a link to the full version,
and explains that your prompts, reference images and results are stored here, that admins and backend owners can see
them, and that anything you share is visible to other members. Choose **I Understand and Agree** to continue, or
**I Do Not Agree** to sign out and leave.

## Making things

The **Image**, **Video**, **Audio** and **3D Model** pages all work the same way:

1. If there's more than one **Style**, pick one. Each style is a different ComfyUI workflow; its description says
   what it's good at.
2. Fill in **Describe what you want**.
3. Pick a **Shape** (square, landscape, portrait, wide or tall) where the style supports it.
4. Optionally open **More options**:
   - **Avoid**: things you don't want in the result, like "blurry, text".
   - **Seed**: leave blank for a random result each time, or enter a number to reproduce one.
5. Some styles also ask for a **Length** in seconds (video and audio), a **Reference image** / **Starting frame** /
   **Picture of the object**, **Quality**, **Prompt strength**, **How much to change the reference**, **Lyrics**, or
   **How many** outputs to make — only when that style's workflow uses them.
6. If you can use more than one Comfier Agent server, you can pick one under **Run on**, or leave it on
   **Auto (fastest)**. Under the form you'll see roughly when your job should finish.
7. Choose **Generate**.

If your job might run on a server that belongs to someone else, a note under the form says so. That server's owner
can see your prompt, images and results.

On the **Video** page, when Chat is available, **Write a script** under the description asks Chat to turn your idea
into a script for the chosen **Length** and **Shape**. You stay on the page: a spinner shows while it writes, and
**Cancel** stops waiting and leaves your description as it was. When the script is ready it replaces
**Describe what you want**; edit it if you like, or choose **Undo** to get your original back. If Chat fails, Comfier
tries once more and tells you if that fails too.

Your request appears under **Recent** straight away and updates by itself as it goes from queued to generating to
done. You can leave the page; the work carries on without you.

A page only shows the fields the chosen style uses. If a page says it has no workflow yet, an admin needs to add one.

## Results

**Results** shows everything you've made, newest first. Use the chips at the top to show one kind (Image, Video,
Audio, 3D Model) or only things that are still generating or that failed.

If a video ever says it didn't load, press **Reload** on it. The failure is logged so admins can look into it.

Each card shows the **style** that was used. Shared results have a small green share icon in the lower-right corner of the thumbnail.

Select a result to open it. From there you can:

- **Download** each output file.
- **Run again**: the same request with the same settings.
- **Tweak**: open the form pre-filled with this result's settings, so you can change something and generate again.
- **Delete** it, from the **⋯** menu.

While a job is queued or running you can **Cancel** it from its page.

If something failed, the result's page explains why, for example that no server was available, that ComfyUI
rejected the workflow, which step failed, or that the server ran out of memory. If a server disconnects mid-job,
Comfier retries the job on another server by itself.

On a finished result you can **Share with everyone** from the **⋯** menu. Choose whether to include the prompt
and/or reference image. Shared results appear under **Shared** for every signed-in member. Choose **Stop sharing**
to take yours back.

Image results also offer **Use as reference**, which opens the Image page with that output attached as your
reference image.

Finished audio results offer **Create album art**. It queues a square image made from the track's description and
lyrics, and once it's done the cover shows in the track's player on its page, in Results, and on shared and public
pages. The image is also a result of its own, linked from the track's page under **Album art**. Choose **New album
art** to make another; the newest one replaces the cover.

## Shared

**Shared** is a gallery of results members chose to make public. Filter by kind or **Only mine**. Open one to see
the output and, if the sharer included them, the prompt and reference. **Try this prompt** opens the studio
pre-filled when the prompt was shared.

## Queue

**Queue** shows every job waiting on or running on ComfyUI, with an estimate of when each will finish and when the
queue will clear. Your own jobs show your prompt; other people's don't (admins see all). The number beside **Queue**
in the navbar updates as jobs start and finish.

## Chat

When your admins have connected a LiteLLM proxy, **Chat** appears in the navbar (after **3D Model**). It is a simple
text chat with your organization's models — not ComfyUI generation.

- Choose **New chat** or pick an earlier conversation from the list on the left.
- Type a message and choose **Send**. **Shift+Enter** adds a new line; **Enter** sends.
- Pick a **model** from the menu before sending; the list comes from LiteLLM. Vision-capable models can take an
  **Image** attachment with your message.
- Replies appear when they're ready; you can leave the page and come back. If a reply fails, choose **Retry**.
- Delete a conversation from the **⋯** menu at the top of the thread.

Admins may show a notice at the top of Chat (for example, linking to a more capable chat system elsewhere). Configure
that under **Settings → Chat**, along with the message **Write a script** on the Video page sends to the default chat model (its
`{{prompt}}`, `{{duration}}`, `{{width}}`, `{{height}}`, `{{aspect_ratio}}` and `{{orientation}}` tokens are filled
from the form).

## Settings

**Your preferences** fill in the forms for you. You can still change them each time.

- **Default shape**: the shape selected when you open a page.
- **Always avoid**: pre-filled into **Avoid** under **More options**, for styles that support it.
- **Server**: only shown when there's more than one. Leave it on **Automatic (least busy)** unless you've been asked
  to use a particular one.
- **Where your jobs run**: shown once you can use Comfier Agent servers. **Fastest available** picks whichever
  server should finish first. **Prefer my servers** uses your own when they can run the job, **Only my servers**
  never sends your work to anyone else's, and **Any server** ignores ownership entirely.

### Notifications

Comfier can tell you when something you made is ready, fails, or is cancelled, so you don't have to keep the page
open. Turn on either or both under **Settings → Notifications**:

- **Email**: sent to the email address on your sign-in account.
- **Slack**: a direct message from the Comfier bot, to the Slack account linked to your sign-in account.
- **Include the finished file**: attaches the result to the email or Slack message. Files too large to attach are
  left out, and the message links to the result instead.

You can't change the email address or Slack account here; they come from your sign-in account. If a switch is greyed
out, the note under it says why: the server may not have email or Slack set up, or your account may not be linked to
Slack yet. Once your admins link it, sign out and back in.

Notifications are off until you turn them on.

## Servers

**Servers** lists the ComfyUI servers you can use through the Comfier Agent: your own, ones people shared with you,
and ones open to everyone. Each shows whether it's online, what it's doing, and how busy it is. Open one to see its
current job, its queue, which styles it can run, installed models, downloads and usage charts. The page updates by
itself.

Unlike backends, which Comfier's server has to reach, an agent server connects **out** to Comfier, so it works from
a home network without opening a port. Members can add their own unless an admin has turned that off.

### Adding a server

1. Choose **Servers → + Add a server**.
2. Give it a **Name** and, optionally, a description.
3. Under **Who can use it**, choose **Only you**, **You and the people listed below** (then enter their email
   addresses, one per line, under **Share with**), or **Everyone on Comfier**.
4. Choose **Add server and create a key**. Copy the key now; you won't see it again.
5. Follow the steps on the page to install the Comfier Agent into ComfyUI, give it Comfier's address and the key,
   and restart ComfyUI. The page shows when the server connects.

The key can also be pasted into the **Comfier** tab in ComfyUI's sidebar, which shows whether the agent is
connected and, if not, why.

**On an Apple Silicon Mac** you don't need ComfyUI: the setup page also shows three commands that install the
agent as a service with **mflux** (images) and **mlx-video** (video), which run natively on the Mac. They can run
alongside ComfyUI too.
`comfier-agent doctor` checks the setup and `comfier-agent logs -f` shows what it's doing.

The server's **Status** card shows which agent version it runs. **Update available** means this Comfier comes with
a newer agent: reinstall it on the server from the steps above. **Newer than Comfier** means the server's agent is
newer than this Comfier, so Comfier itself needs updating.

### Your server's settings

Open your server and choose **Settings**:

- **Who can use it** and **Share with**: as when adding it. People who use your server can't see your other jobs,
  but **you can see their prompts, images and results**; Comfier warns them before a job runs on your server.
- **Run my jobs before other people's**: your work jumps ahead of other people's waiting jobs.
- **Most waiting jobs per other person**: stops one person filling your queue.
- **Styles it runs**: limit the server to some styles; select none to run every style.
- **Model downloads**: whether Comfier may download the models a style needs onto this server: never, only for your
  jobs, or for anyone's.

**Pause** stops new jobs going to the server without disconnecting it; **Resume** starts them again. To delete a
server, open **Settings** and use the **⋯** menu. Its key stops working and its waiting jobs move to other servers.

### Keys

The **Keys** card on your server's page lists its keys and when each was last used. **New key** makes a replacement
and shows it once. The old key keeps working for 24 hours so you have time to update ComfyUI, unless you tick
**Stop the old key working now**. **Revoke** stops a key at once and disconnects any server using it.

### Downloads and download tokens

When a style needs a model your server doesn't have, Comfier can download it onto the server (see **Model
downloads** above). Downloads in progress show on the server's page, where you can cancel them. Some models need an
account, like gated Hugging Face repos or Civitai. Add a token for that site under **Settings → Download tokens**.
Tokens are stored encrypted, only the last four characters are ever shown, and each is only sent to its own site.

## For admins: backends

A backend is a ComfyUI server Comfier sends work to. Find them under **Settings → Backends**.

- **ComfyUI URL**: the address Comfier's server uses to reach ComfyUI, such as `http://gpu-box:8188`.
- **Auth token**: only needed if ComfyUI sits behind a proxy that expects a bearer token. It's stored encrypted.
  Leave the field blank when editing to keep the saved token, or tick **Remove saved token**.
- **Send new work to this backend**: turn it off to take a server out of rotation without deleting it.
- **Delete backend files after each run**: once Comfier finishes with a result (success or failure), remove the
  uploaded input, generated outputs, preview files, and the ComfyUI history entry from that server. Comfier keeps
  the copies it downloaded. File deletion needs the Comfier downloader node installed on the backend; without it,
  only the history entry is cleared.

Comfier checks a backend when you save it; choose **Test** in the list to check it again. With several enabled backends, each
new request goes to the reachable one with the shortest queue, unless the user picked a server in their settings.

To move a backend to the Comfier Agent, choose **Switch to the Comfier Agent** from its **⋯** menu. Comfier makes a
key and shows the install steps; the server keeps its history.

Admins also get **Settings → Server overview**, with load and job charts for every agent server and a link to
**Prediction accuracy**, which compares Comfier's time estimates with how long jobs really took. **Settings → Global
download tokens** holds tokens used for downloads onto any server, and **Settings → Notifications → Servers** turns
member-added servers on or off.

## For admins: workflows

A workflow decides what one style on one page does. Find them under **Settings → Workflows**.

1. Build and test the workflow in ComfyUI.
2. Export it twice: **Workflow → Export (API)** for the workflow itself, and **Workflow → Export** if you want
   Comfier to pick up model download links from ComfyUI templates.
3. In Comfier, choose **Add workflow** (or open an existing one). At the top, upload one or both export files
   together, then either edit placeholders by hand or choose **Suggest placeholders**.
4. Replace the values users should control with placeholders (or let the assistant suggest them):

   | Placeholder | Becomes |
   |---|---|
   | `{{prompt}}` | Describe what you want |
   | `{{negative_prompt}}` | Avoid |
   | `{{seed}}` | Seed (random if left blank) |
   | `{{width}}`, `{{height}}` | The chosen shape at the workflow's base resolution |
   | `{{duration}}` | Length in seconds |
   | `{{frames}}` | Length × frame rate + 1 |
   | `{{fps}}` | The style's frame rate (for a node that sets the video's fps) |
   | `{{image}}` | The uploaded starting image or picture of the object |

5. Pick the **Page** it belongs to, paste or upload the API JSON if you haven't already, and choose **Save**.
6. Set **Base resolution** to the size the model was trained at (for example 512 for SD 1.5, 1024 for SDXL), and
   **Frame rate** for video.
7. Leave **Offer this to users** ticked, and use **Order** to decide which style is listed first.

**Suggest placeholders** classifies inputs with built-in rules: sampler seed, steps and cfg, empty-latent size,
batch and frame count, LoadImage filenames, prompt text by whether it feeds a sampler's positive or negative
input, and denoise only when the sampler starts from an encoded image. If LiteLLM is configured (`LITELLM_URL`,
`LITELLM_MODEL` and optionally `LITELLM_API_KEY` in `.env`), the few inputs the rules can't place are sent to the
LLM, which replies with a list of substitutions — never a rewritten workflow. Comfier shows every proposed change in
a table; untick any you don't want, add others with **Add by hand**, then choose **Save**. Only the ticked changes
are written, and nothing else in the JSON changes. Without an LLM, inputs the rules couldn't place are listed so
you can add them yourself. Edit the LLM's system prompt under **Settings → Workflow assistant**. Member-facing
**Chat** uses the same LiteLLM proxy; set its default model, optional top-of-page notice and video script prompt under **Settings → Chat**.

Under **Settings → Album art**, choose which image style **Create album art** uses (by default, the first enabled
image style that works from a prompt alone) and edit the prompt it sends. `{{prompt}}` is the track's description and
`{{lyrics}}` its lyrics, with section markers such as `[verse]` removed and long lyrics shortened; text between
`{{#lyrics}}` and `{{/lyrics}}` is left out for tracks without lyrics.

#### mflux and MLX video workflows (Macs)

A workflow can **Run on** mflux (images) or MLX video instead of ComfyUI. These run natively on Apple Silicon Macs
whose agent has the engine. There's no node graph; the workflow is a **recipe**: the command to run and its options,
as JSON, with the same placeholders.

1. In **Add workflow**, set **Runs on** to **mflux** or **MLX video**.
2. Pick a preset under **Start from a preset** (for example Z-Image Turbo or FLUX.1 dev), then adjust it. Keys are
   the command's flags in snake_case: `"image_strength": 0.4` is `--image-strength 0.4`, `true` is a bare flag.
3. Set `min_memory_gb` to what the model needs. Macs with less memory aren't offered the style.
4. Save. The style only goes to Macs that run the engine. A Mac that hasn't downloaded the model yet still takes the
   job, but the first run is slower while it downloads. To avoid that, open the Mac's page under **Servers** and
   choose **Download** next to the style (or **Download all**); progress shows under **Downloads**.

To remove a workflow, open it (or use the **⋯** menu on the list) and choose **Delete**. Past results stay; they just
lose the link back to this style.

**Settings → Needs attention** lists pages that have no workflow, backends that can't be reached, and workflows
whose models are missing from a backend.

### Models

Saving a workflow takes you to its page, which ends with **Models on your backends**: every model file the workflow
loads, and whether each backend has it. A green dot means installed; **Missing** means that backend doesn't have it;
**—** means that backend hasn't been checked yet. Comfier only sends a style's jobs to backends that have all of its
models, so a missing model never turns into a failed job.

Comfier finds the files from the workflow's loader nodes by itself. To let it install them, it also needs a download
link for each one. Either:

- type them into **Models**, one per line: the folder, a slash, the file name, a space and a direct link, like
  `vae/wan_2.1_vae.safetensors https://huggingface.co/…/wan_2.1_vae.safetensors`; or
- upload the regular export at the top of the workflow form (**Regular export**). Workflows based on ComfyUI's
  templates carry their download links in that file.

For Hugging Face, use the link to the file (`…/resolve/main/…`), not its web page (`…/blob/main/…`). Comfier fixes
`/blob/` links for you, and the downloader refuses anything that turns out to be a web page.

Then choose **Install N missing** under a backend. N counts only the files that backend can actually fetch. Progress
appears in the table as it happens; big models can take a while.

Anything that won't install is listed under the table in a **needs attention** box, with the reason and what to do:
a download that failed (for example a login is needed, or the link is wrong), a file with no link, or a file that
ComfyUI-Manager can't provide. A backend that only has Manager can install just the files in Manager's catalog, and
many workflows use files that aren't there; install the Comfier downloader node on it (see the README) to download
anything. Once you've fixed the cause, choose **Install** again to retry.

Choose **Re-check** after adding or removing model files on a server by hand, or after installing the downloader node.

#### On agent servers

The workflow page's **Agent servers** button (marked **needs review** when Comfier found something to confirm) lists
the model files the workflow needs, where Comfier found each one, and its download link. Correct a folder, file
name or link there, add a file in the blank last row, or remove one Comfier picked up by mistake, and choose
**Save**. Comfier keeps your edits when it re-reads the workflow.

Below that, every agent server shows whether it can run the workflow now, needs downloads first, or can't run it
and why (for example a missing custom node or not enough GPU memory). Tick the servers that need downloads and
choose **Prepare selected servers** to download everything they're missing ahead of the first job.

## How-to

### How to reproduce a result exactly

1. Open the result from **Results**.
2. Choose **Run again**. The same seed and settings are used.

### How to make a variation of a result

1. Open the result and choose **Tweak**.
2. Change the prompt or shape, and clear **Seed** under **More options** if you want a different take.
3. Choose **Generate**.

### How to get a message when your work is done

1. Open **Settings**.
2. Under **Notifications**, turn on **Email**, **Slack**, or both.
3. Turn on **Include the finished file** if you want the result attached.
4. Choose **Save**.

### How to stop seeing the same unwanted things

1. Go to **Settings**.
2. Add them to **Always avoid**, separated by commas, and choose **Save**.

### How to take a ComfyUI server offline for maintenance (admins)

1. Go to **Settings → Backends** and open the server.
2. Untick **Send new work to this backend** and choose **Save**. Work already running on it finishes normally.

### How to add a ComfyUI template as a workflow (admins)

1. In ComfyUI, open the template from **Workflow → Browse Templates** and check it works.
2. Save it twice: **Workflow → Export (API)** for the workflow itself, and **Workflow → Export** for its download links.
3. In Comfier, add the workflow and upload both files at the top of the form. Use **Suggest placeholders** or add
   placeholders by hand, then choose **Save**.
4. On the workflow's page, choose **Install N missing** for each backend that needs the models.

### How to update the Code of Conduct and privacy notice (admins)

1. Go to **Settings → Code of Conduct & privacy**.
2. Edit the text, the link to the full Code of Conduct, and the page people are sent to when they choose
   **I Do Not Agree** (Disney's home page by default). Tick **Ask everyone to agree again** if the change is important enough that existing members
   should re-read it; leave it unticked for minor wording fixes.
3. Choose **Save**.

### How to check the job queue (admins)

Go to **Settings → Job queue** to open the Sidekiq dashboard, which shows jobs waiting, running and retrying.
