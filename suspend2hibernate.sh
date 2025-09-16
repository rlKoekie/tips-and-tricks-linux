#!/bin/bash
# !!! MAKE SURE TO CLOSE THE LID OF YOUR LAPTOP WHEN SUSPENDING IT AND USING THIS SCRIPT!!! #

# BSD 3-Clause License

# Copyright (c) 2025, Hans van Schoot

# Redistribution and use in source and binary forms, with or without
# modification, are permitted provided that the following conditions are met:

# 1. Redistributions of source code must retain the above copyright notice, this
#    list of conditions and the following disclaimer.

# 2. Redistributions in binary form must reproduce the above copyright notice,
#    this list of conditions and the following disclaimer in the documentation
#    and/or other materials provided with the distribution.

# 3. Neither the name of the copyright holder nor the names of its
#    contributors may be used to endorse or promote products derived from
#    this software without specific prior written permission.

# THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
# AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
# IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
# DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE
# FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
# DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR
# SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER
# CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY,
# OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
# OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

# This script attempts to fix the suspend-then-hibernate issue where a laptop sometimes fails to go into hibernation after the desired suspend period. Common symptoms are:
## Very hot laptop in backpack
## Unexpected fully drained batteries
## Notification beeps in the middle of the night

# This script works by checking if the lid is open when the laptop wakes up. If the lid is closed, we assume the laptop is supposed to be in suspend/hibernate. If the lid is open, exit the script.
# At least on the Intel 12th gen FW13 laptop it seems that the reported wakeup event is always "Power Button", so we cannot use this for figuring out if the laptop was intentionally woken or if it woke up by itself.

# So far, this script has been successfully tested on:
# * Framework 13 laptop, 12th Gen Intel

### USER DEFINED SECTION ###
# how long to suspend before hibernating to disk, in seconds
suspendlength=10800
logfile=/tmp/suspend2hibernate.log
### END USER DEFINED SECTION ###

# pipe all output to logfile
exec 3>&1 4>&2 
exec >> "$logfile" 2>&1

### some utility functions ###
lidclosed () {
	lidstate=`cat /proc/acpi/button/lid/LID0/state`
	if test "${lidstate}" != "${lidstate%closed}"; then
        #	echo "detected a closed lid"
		return 0
	else    
	#	echo "detected an open lid"
		return 1
	fi      
}

batterypercentage () {
	# find the battery, it could be BAT0 or BAT1
	mybat=`ls -1 /sys/class/power_supply/BAT*/capacity | head -n 1`
	if test -z "$mybat"; then
		echo "we failed to locate a battery, just report a full one" 1>&2
		echo 100
	else
		cat $mybat
	fi
}

batterydischarging () {
	# find the battery, it could be BAT0 or BAT1
	mybat=`ls -1 /sys/class/power_supply/BAT*/status | head -n 1`
	# we return true if we are in a Discharging state, AND below 95% battery
	# A framework laptop can report "Discharging" OR "Not charging" while the charger is connected and the battery is full, this is part of their over-charging protection.
	if test "$(cat "$mybat")" = "Discharging" -a $(batterypercentage) -lt 95; then
		return 0
	else
		return 1
	fi
}

### main script ###
starttime=`date +%s`
date
if test $(batterypercentage) -lt 10 ; then
	# battery is almost empty, go straight to hibernation instead of suspend!
	if batterydischarging; then
		echo "low battery detected, going straight to hibernate"
		systemctl hibernate
		sleep 5 
		echo "finished hibernate, exiting now"
		exit
	fi
fi

# locking the desktop session, and putting the system in suspend. We do not use "systemctl suspend" for this, as that is a non-blocking (asynchronous) call. The rtcwake command allows us to set a suspend duration, and is blocking (it returns control to the script after waking up, not before). 
echo "suspending the system for $suspendlength seconds"
xdg-screensaver lock; sleep 2
sudo rtcwake -m mem --date +${suspendlength}sec
sleep 5 
date

### suspend loop
# - After getting control back (after suspend OR hibernate) we check:
# -- how long were we out (calculate timediff)
# -- is the lid open?
# if we get control back too early with a closed lid (I have not yet observed this in script with the laptop sitting on a desk), we put the system back into suspend for the remaining duration.
while test $(($(date +%s)-$starttime)) -lt $suspendlength; do
	sleep 1
	echo "inside the suspend loop, this happens if we wake from suspend prematurely"
	if ! lidclosed; then
		echo "lid is open, breaking from suspend loop"
		break
	fi
	timeleft=$(($starttime+$suspendlength-$(date +%s)))
	echo "going into suspend for $timeleft seconds"
	xdg-screensaver lock; sleep 2
	sudo rtcwake -m mem --date +${timeleft}sec
	sleep 5
done

date
### suspend or hibernate? ###
# we suspended for the requested duration, we now check if we are on wall power.
# If we are there is no need to hibernate, so we suspend instead
while ! batterydischarging; do
	date
	if lidclosed; then
		echo "lid closed and on AC power (or full battery), suspend for ${suspendlength} sec"
		xdg-screensaver lock; sleep 2
		sudo rtcwake -m mem --date +${suspendlength}sec
		sleep 5
	else
		break
	fi
done

### hibernate ###
# We are past the requested suspend duration, and without wall power.
# If the lid is closed, put the system in hibernation.
if lidclosed; then
	echo "lid is closed, waiting 5 seconds"
	sleep 5
	date
	echo "time to go into hibernate now"
	systemctl hibernate
else
	echo "lid is open, not doing anything else"
	exit
fi

# end of piping output to logfile
exec 1>&3 2>&4
