<? include "header.php" ?>

<h1 align=center>ramen</h1>



<a name="NAME"></a>
<h2>NAME</h2>


<p style="margin-left:11%; margin-top: 1em">Ramen - Ramen
Stream Processor</p>

<a name="SYNOPSIS"></a>
<h2>SYNOPSIS</h2>


<p style="margin-left:11%; margin-top: 1em"><b>Ramen</b>
<i>COMMAND</i> ...</p>

<a name="COMMANDS"></a>
<h2>COMMANDS</h2>



<p style="margin-left:11%; margin-top: 1em"><b>_completion</b></p>

<p style="margin-left:17%;">Autocomplete the given
command</p>

<p style="margin-left:11%;"><b>_expand</b></p>

<p style="margin-left:17%;">test graphite query
expansion</p>

<p style="margin-left:11%;"><b>archivist</b></p>

<p style="margin-left:17%;">Allocate disk for storage</p>

<p style="margin-left:11%;"><b>compile</b></p>

<p style="margin-left:17%;">Compile each given source file
into an executable</p>

<p style="margin-left:11%;"><b>dequeue</b></p>

<p style="margin-left:17%;">Dequeue a message from a
ringbuffer</p>

<table width="100%" border=0 rules="none" frame="void"
       cellspacing="0" cellpadding="0">
<tr valign="top" align="left">
<td width="11%"></td>
<td width="3%">


<p style="margin-top: 1em" valign="top"><b>gc</b></p></td>
<td width="3%"></td>
<td width="40%">


<p style="margin-top: 1em" valign="top">Delete old or
unused files</p></td>
<td width="43%">
</td>
</table>

<p style="margin-left:11%;"><b>httpd</b></p>

<p style="margin-left:17%;">Start an HTTP server</p>

<p style="margin-left:11%;"><b>kill</b></p>

<p style="margin-left:17%;">Stop a program</p>

<p style="margin-left:11%;"><b>links</b></p>

<p style="margin-left:17%;">List all in use ring buffers
with some statistics</p>

<p style="margin-left:11%;"><b>notifier</b></p>

<p style="margin-left:17%;">Start the notifier</p>

<p style="margin-left:11%;"><b>notify</b></p>

<p style="margin-left:17%;">Send a notification</p>

<table width="100%" border=0 rules="none" frame="void"
       cellspacing="0" cellpadding="0">
<tr valign="top" align="left">
<td width="11%"></td>
<td width="3%">


<p style="margin-top: 1em" valign="top"><b>ps</b></p></td>
<td width="3%"></td>
<td width="54%">


<p style="margin-top: 1em" valign="top">Display info about
running programs</p></td>
<td width="29%">
</td>
</table>

<p style="margin-left:11%;"><b>repair-ringbuf</b></p>

<p style="margin-left:17%;">Repair a ringbuf header,
assuming no readers/writers</p>

<p style="margin-left:11%;"><b>replay</b></p>

<p style="margin-left:17%;">Rebuild the past output of the
given operation</p>

<p style="margin-left:11%;"><b>ringbuf-summary</b></p>

<p style="margin-left:17%;">Dump info about a
ring-buffer</p>

<table width="100%" border=0 rules="none" frame="void"
       cellspacing="0" cellpadding="0">
<tr valign="top" align="left">
<td width="11%"></td>
<td width="4%">


<p style="margin-top: 1em" valign="top"><b>run</b></p></td>
<td width="2%"></td>
<td width="61%">


<p style="margin-top: 1em" valign="top">Run one (or
several) compiled program(s)</p></td>
<td width="22%">
</td>
</table>

<p style="margin-left:11%;"><b>stats</b></p>

<p style="margin-left:17%;">Display internal statistics</p>

<p style="margin-left:11%;"><b>supervisor</b></p>

<p style="margin-left:17%;">Start the processes
supervisor</p>

<p style="margin-left:11%;"><b>tail</b></p>

<p style="margin-left:17%;">Display the last outputs of an
operation</p>

<p style="margin-left:11%;"><b>test</b></p>

<p style="margin-left:17%;">Test a configuration against
one or several tests</p>

<p style="margin-left:11%;"><b>timerange</b></p>

<p style="margin-left:17%;">Retrieve the available time
range of an operation output</p>

<p style="margin-left:11%;"><b>timeseries</b></p>

<p style="margin-left:17%;">Extract a time series from an
operation</p>

<p style="margin-left:11%;"><b>variants</b></p>

<p style="margin-left:17%;">Display the experimenter
identifier and variants</p>

<a name="COMMON OPTIONS"></a>
<h2>COMMON OPTIONS</h2>



<p style="margin-left:11%; margin-top: 1em"><b>--help</b>[=<i>FMT</i>]
(default=auto)</p>

<p style="margin-left:17%;">Show this help in format
<i>FMT</i>. The value <i>FMT</i> must be one of
&lsquo;auto', &lsquo;pager', &lsquo;groff' or &lsquo;plain'.
With &lsquo;auto', the format is &lsquo;pager&lsquo; or
&lsquo;plain' whenever the <b>TERM</b> env var is
&lsquo;dumb' or undefined.</p>

<p style="margin-left:11%;"><b>--version</b></p>

<p style="margin-left:17%;">Show version information.</p>
<? include "footer.php" ?>
