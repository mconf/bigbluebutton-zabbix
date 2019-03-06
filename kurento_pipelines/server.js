/*
 * (C) Copyright 2014-2015 Kurento (http://kurento.org/)
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *   http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 *
 */

var path = require('path');
var url = require('url');
var cookieParser = require('cookie-parser')
var express = require('express');
var session = require('express-session')
var minimist = require('minimist');
var ws = require('ws');
var kurento = require('kurento-client');
var fs = require('fs');
var https = require('https');

var argv = minimist(process.argv.slice(1), {
    default: {
        ws_uri: 'ws://127.0.0.1:8888/kurento'
    }
});

/*
 * Definition of global variables.
 */
var kurentoClient = null;
var serverManager = null;
var mediaPipelines = {};
var endpointsCount = 0;

function formatFloat(n) {
    return +n.toFixed(3);
}

getKurentoClient(function (error, kurentoClient) {
    kurentoClient.getServerManager(function (error, server) {
        if (error) {
            console.log("getServerManager failed: " + error);
            return;
        }
        serverManager = server;
        getInfo(serverManager, function (error) {
            if (error) {
                return;
            }

            var staleEndpoints = 0;
            var stalePipelines = 0;
            var staleRtp = 0;
            var staleWebrtc = 0;

            var info = { "audio": {}, "video": {} };
            ["audio", "video"].forEach(function(media) {
                info[media]["duplex"] = 0;
                info[media]["rtp"] = 0;
                info[media]["webrtc"] = 0;
                ["inbound", "outbound"].forEach(function(direction) {
                    info[media][direction] = 0;
                    info[media][direction + "PacketsLostRateList"] = [];
                    info[media][direction + "SumPacketsLost"] = 0;
                    info[media][direction + "AvgPacketsLostRate"] = 0;
                    info[media][direction + "MaxPacketsLostRate"] = 0;
                    info[media][direction + "JitterList"] = [];
                    info[media][direction + "AvgJitter"] = 0;
                    info[media][direction + "MaxJitter"] = 0;
                });
            });

            for (var pipelineId in mediaPipelines) {
                var pipeline = mediaPipelines[pipelineId];
                var itemStaleEndpoint = 0;
                for (var mediaEndpointId in pipeline.endpoints) {
                    var mediaEndpoint = pipeline.endpoints[mediaEndpointId];

                    var rtp = false;
                    var webrtc = false;
                    if (mediaEndpointId.indexOf("kurento.RtpEndpoint") != -1) {
                        rtp = true;
                    } else if (mediaEndpointId.indexOf("kurento.WebRtcEndpoint") != -1) {
                        webrtc = true;
                    }

                    var inbound = false;
                    var outbound = false;
                    ["audio", "video"].every(function(media, index) {
                        for (var key in mediaEndpoint[media].stats) {
                            if (mediaEndpoint[media].stats[key].type == "outboundrtp" && mediaEndpoint[media].stats[key].bytesSent > 0) {
                                outbound = true;

                                if (mediaEndpoint[media].stats[key].hasOwnProperty("packetsLost")) {
                                    info[media].outboundSumPacketsLost += mediaEndpoint[media].stats[key].packetsLost;
                                    if (mediaEndpoint[media].stats[key].hasOwnProperty("packetsSent")) {
                                        info[media].outboundPacketsLostRateList.push(mediaEndpoint[media].stats[key].packetsLost / (mediaEndpoint[media].stats[key].packetsLost + mediaEndpoint[media].stats[key].packetsSent));
                                    }
                                }
                                if (mediaEndpoint[media].stats[key].hasOwnProperty("jitter")) {
                                    info[media].outboundJitterList.push(mediaEndpoint[media].stats[key].jitter);
                                }
                            }
                            if (mediaEndpoint[media].stats[key].type == "inboundrtp" && mediaEndpoint[media].stats[key].bytesReceived > 0) {
                                inbound = true;

                                if (mediaEndpoint[media].stats[key].hasOwnProperty("packetsLost")) {
                                    info[media].inboundSumPacketsLost += mediaEndpoint[media].stats[key].packetsLost;
                                    if (mediaEndpoint[media].stats[key].hasOwnProperty("packetsReceived")) {
                                        info[media].inboundPacketsLostRateList.push(mediaEndpoint[media].stats[key].packetsLost / (mediaEndpoint[media].stats[key].packetsLost + mediaEndpoint[media].stats[key].packetsReceived));
                                    }
                                }
                                if (mediaEndpoint[media].stats[key].hasOwnProperty("jitter")) {
                                    info[media].inboundJitterList.push(mediaEndpoint[media].stats[key].jitter);
                                }
                            }
                        }
                        if (inbound) {
                            if (outbound) {
                                info[media].duplex++;
                            } else {
                                info[media].inbound++;
                            }
                        } else {
                            if (outbound) {
                                info[media].outbound++;
                            } else {
                                
                            }
                        }
                        if (inbound || outbound) {
                            if (rtp) {
                                info[media].rtp++;
                            } else if (webrtc) {
                                info[media].webrtc++;
                            }
                            return false;
                        }
                        return true;
                    })
                    if (! inbound && ! outbound) {
                        if (rtp) {
                            staleRtp++;
                        } else if (webrtc) {
                            staleWebrtc++;
                        }
                        itemStaleEndpoint++;
                    }
                }
                staleEndpoints += itemStaleEndpoint;
                if (Object.keys(pipeline.endpoints).length == itemStaleEndpoint) {
                    stalePipelines++;
                }
            }

            var output = "pipelines: " + Object.keys(mediaPipelines).length
                + ", endpoints: " + endpointsCount
                + ", stale_pipelines: " + stalePipelines
                + ", stale_endpoints: " + staleEndpoints
                + ", stale_endpoints_rtp: " + staleRtp
                + ", stale_endpoints_webrtc: " + staleWebrtc;
            
            ["audio", "video"].forEach(function(media) {
                output += "\n" + media + "_endpoints: " + (info[media].inbound + info[media].outbound + info[media].duplex);
                output += ", " + media + "_duplex_endpoints: " + info[media].duplex;
                output += ", " + media + "_inbound_endpoints: " + info[media].inbound;

                if (info[media].inboundPacketsLostRateList.length > 0) {
                    let inboundSumPacketsLostRate = info[media].inboundPacketsLostRateList.reduce((previous, current) => current += previous);
                    let inboundAvgPacketsLostRate = info[media].inboundSumPacketsLostRate / info[media].inboundPacketsLostRateList.length;
                    let inboundMaxPacketsLostRate = Math.max.apply(null, info[media].inboundPacketsLostRateList);
                    output += ", " + media + "_inbound_avg_packet_loss_rate: " + formatFloat(info[media].inboundAvgPacketsLostRate)
                        + ", " + media + "_inbound_max_packet_loss_rate: " + formatFloat(info[media].inboundMaxPacketsLostRate)
                        + ", " + media + "_inbound_sum_packet_loss: " + info[media].inboundSumPacketsLost;
                }
                if (info[media].inboundJitterList.length > 0) {
                    let inboundSumJitter = info[media].inboundJitterList.reduce((previous, current) => current += previous);
                    let inboundAvgJitter = info[media].inboundSumJitter / info[media].inboundJitterList.length;
                    let inboundMaxJitter = Math.max.apply(null, info[media].inboundJitterList);
                    output += ", " + media + "_inbound_avg_jitter: " + formatFloat(info[media].inboundAvgJitter)
                        + ", " + media + "_inbound_max_jitter: " + formatFloat(info[media].inboundMaxJitter);
                }

                output += ", " + media + "_outbound_endpoints: " + info[media].outbound;
                if (info[media].outboundPacketsLostRateList.length > 0) {
                    let outboundSumPacketsLostRate = info[media].outboundPacketsLostRateList.reduce((previous, current) => current += previous);
                    let outboundAvgPacketsLostRate = info[media].outboundSumPacketsLostRate / info[media].outboundPacketsLostRateList.length;
                    let outboundMaxPacketsLostRate = Math.max.apply(null, info[media].outboundPacketsLostRateList);
                    output += ", " + media + "_outbound_avg_packet_loss_rate: " + formatFloat(info[media].outboundAvgPacketsLostRate)
                        + ", " + media + "_outbound_max_packet_loss_rate: " + formatFloat(info[media].outboundMaxPacketsLostRate)
                        + ", " + media + "_outbound_sum_packet_loss: " + info[media].outboundSumPacketsLost;
                }
                if (info[media].outboundJitterList.length > 0) {
                    let outboundSumJitter = info[media].outboundJitterList.reduce((previous, current) => current += previous);
                    let outboundAvgJitter = info[media].outboundSumJitter / info[media].outboundJitterList.length;
                    let outboundMaxJitter = Math.max.apply(null, info[media].outboundJitterList);
                    output += ", " + media + "_outbound_avg_jitter: " + formatFloat(info[media].outboundAvgJitter)
                        + ", " + media + "_outbound_max_jitter: " + formatFloat(info[media].outboundMaxJitter);
                }
                output += ", " + media + "_rtp_endpoints: " + info[media].rtp;
                output += ", " + media + "_webrtc_endpoints: " + info[media].webrtc;
            });

            console.log(output);
            process.exit(0);
        });
    });
});

/*
 * Definition of functions
 */

// Recover kurentoClient for the first time.
function getKurentoClient(callback) {
    if (kurentoClient !== null) {
        return callback(null, kurentoClient);
    }

    kurento(argv.ws_uri, function (error, _kurentoClient) {
        if (error) {
            console.log("Could not find media server at address " + argv.ws_uri);
            return callback("Could not find media server at address" + argv.ws_uri
                + ". Exiting with error " + error);
        }

        kurentoClient = _kurentoClient;
        callback(null, kurentoClient);
    });
}

function getInfo(server, callback) {
    if (!server) {
        return callback('error - failed to find server');
    }

    server.getInfo(function (error, serverInfo) {
        if (error) {
            return callback(error);
        }

        getPipelinesInfo(server, callback);
    })
}

function getAllFuncs(obj) {
    var props = [];

    do {
        props = props.concat(Object.getOwnPropertyNames(obj));
    } while (obj = Object.getPrototypeOf(obj));
    return props.filter(function(elem, pos) {
        return props.indexOf(elem) == pos;
    }).sort();
}

function getPipelinesInfo(server, callback) {
    if (!server) {
        return callback('error - failed to find server');
    }

    server.getPipelines(function (error, pipelines) {
        if (error) {
            return callback(error);
        }

        if (pipelines && (pipelines.length < 1)) {
            return callback(null);
        }

        var counter = 0;
        var promises = [];
        var firstPromises = [];
        pipelines.forEach(function (p, index, array) {
            mediaPipelines[p.id] = { "endpoints": {} };
            firstPromises.push(setLatencyStats(p, mediaPipelines[p.id]));
            firstPromises.push(getCreationTime(p, mediaPipelines[p.id]));

            p.getChildren(function (error, elements) {
                endpointsCount += elements.length;
                mediaPipelines[p.id].hasPlayer = elements.length > 1;
                elements.forEach(function (me, index, array) {
                    mediaPipelines[p.id].endpoints[me.id] = { "video": {}, "audio": {} };
                    promises.push(getCreationTime(me, mediaPipelines[p.id].endpoints[me.id]));
                    promises.push(isFlowingIn(me, "VIDEO", mediaPipelines[p.id].endpoints[me.id].video));
                    promises.push(isFlowingIn(me, "AUDIO", mediaPipelines[p.id].endpoints[me.id].audio));
                    promises.push(isFlowingOut(me, "VIDEO", mediaPipelines[p.id].endpoints[me.id].video));
                    promises.push(isFlowingOut(me, "AUDIO", mediaPipelines[p.id].endpoints[me.id].audio));
                    promises.push(getStats(me, "VIDEO", mediaPipelines[p.id].endpoints[me.id].video));
                    promises.push(getStats(me, "AUDIO", mediaPipelines[p.id].endpoints[me.id].audio));
                    promises.push(getMediaState(me, mediaPipelines[p.id].endpoints[me.id]));
                })
                counter++;
                if (counter == pipelines.length) {
                    var rejectPromise = function(error) {
                        return callback(error);
                    }
                    Promise.all(firstPromises).then(function(value) {
                        // Do not retrieve detailed stats to avoid flooding the KMS API
                        return callback();

                        Promise.all(promises).then(function(value) {
                            return callback();
                        }, rejectPromise);
                    }, rejectPromise);
                }
            })
        })
    })
}

var setLatencyStats = function(pipeline, obj) {
    var promise = new Promise(function(resolve, reject) {
        pipeline.setLatencyStats(true, function (error) {
            if (error) {
                reject(error);
            } else {
                resolve();
            }
        });
    });
    return promise;
}

var getCreationTime = function(element, obj) {
    var promise = new Promise(function(resolve, reject) {
        element.getCreationTime(function (error, result) {
            if (error) {
                reject(error);
            } else {
                obj.creationTime = result;
                resolve();
            }
        });
    });
    return promise;
}

var isFlowingIn = function(mediaElement, media, obj) {
    var promise = new Promise(function(resolve, reject) {
        mediaElement.isMediaFlowingIn(media, function (error, result) {
            if (error) {
                reject(error);
            } else {
                obj.mediaFlowingIn = result;
                resolve();
            }
        });
    });
    return promise;
}

var isFlowingOut = function(mediaElement, media, obj) {
    var promise = new Promise(function(resolve, reject) {
        mediaElement.isMediaFlowingOut(media, function (error, result) {
            if (error) {
                reject(error);
            } else {
                obj.mediaFlowingOut = result;
                resolve();
            }
        });
    });
    return promise;
}

var getStats = function(mediaElement, media, obj) {
    var promise = new Promise(function(resolve, reject) {
        mediaElement.getStats(media, function (error, result) {
            if (error) {
                reject(error);
            } else {
                obj.stats = result;
                resolve();
            }
        });
    });
    return promise;
}

var getMediaState = function(mediaElement, obj) {
    var promise = new Promise(function(resolve, reject) {
        mediaElement.getMediaState(function (error, result) {
            if (error) {
                reject(error);
            } else {
                obj.stale = result == "DISCONNECTED";
                resolve();
            }
        });
    });
    return promise;
}
