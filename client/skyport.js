(function($, window, document){
    'use strict';

    var frameQueue = [],
        queueIntervalRef;

    function generateQueue(config) {
        var pages,
            i,
            sha1;

        for (sha1 in config.data) {
            pages = parseInt(config.data[sha1].pages);
            for (i = 1; i <= pages; i++) {
                frameQueue.push('/data/' + sha1 + '/page_' + i + '.png');
            }
        }
    }

    function processQueue() {
        var frame = frameQueue.shift();
        if (!frame) {
            clearInterval(queueIntervalRef);
            initSkyport();
        } else {
            buildFrameAndTransition(frame);
        }
    }

    function buildFrameAndTransition(frame) {
        var $nextFrame = $('<div class="frame next-frame">').css('background-image', 'url(' + frame + ')');
        $('body').append($nextFrame);
        setTimeout(function(){
            $('.current-frame').removeClass('current-frame').addClass('previous-frame');
        }, 0);
        setTimeout(function(){
            $('.next-frame').addClass('current-frame').removeClass('next-frame');
        }, 0);
        setTimeout(function(){
            $('.previous-frame').remove();
        }, 1020);
    }

    function initSkyport() {
        if (window.location.hash === "") {
            $('.boot-msg').text('No key specified');
        } else {
            $.getJSON('/data/' + window.location.hash.slice(1) + '.json', function(response){
                generateQueue(response);
                processQueue();

                var intervalTime = (response.delay) ? (parseInt(response.delay) * 1000) : 30000;
                queueIntervalRef = setInterval(processQueue, intervalTime);

                $(document).on('keyup', function(event) {
                    processQueue();
                });
            }).error(function() {
                $('.boot-msg').text('Error loading configuration');
            });
        }
    }
    $(function(){
        initSkyport();
    });
})($, window, document);